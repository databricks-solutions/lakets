-- =============================================================================
-- LakeTS RollUp Optimization — Modules 23–27
-- Smart refresh, batch processing, DAG orchestration, tier routing,
-- and bulk import invalidation.
--
-- Requires: 00_schema.sql, 03_rollup.sql (applied first via 99_install.sql)
-- =============================================================================

-- ═══════════════════════════════════════════════════════════════════════════════
-- SCHEMA EXTENSIONS
-- ═══════════════════════════════════════════════════════════════════════════════

-- M23: Chunk-skip pruning needs last_modified_at on chunk metadata
ALTER TABLE lakets._chunk_metadata
    ADD COLUMN IF NOT EXISTS last_modified_at TIMESTAMPTZ;

-- M23–M27: New columns on _rollup_registry
ALTER TABLE lakets._rollup_registry
    ADD COLUMN IF NOT EXISTS bucket_column       TEXT    DEFAULT 'bucket',
    ADD COLUMN IF NOT EXISTS source_time_column  TEXT,
    ADD COLUMN IF NOT EXISTS predicate_injection BOOLEAN DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS depends_on          INT[]   DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS cold_query_text     TEXT;

-- Path B removal: drop legacy RollUp->UC export columns (superseded by CDF sync)
ALTER TABLE lakets._rollup_registry
    DROP COLUMN IF EXISTS export_enabled,
    DROP COLUMN IF EXISTS export_delta_table,
    DROP COLUMN IF EXISTS export_mode,
    DROP COLUMN IF EXISTS last_exported_at;

-- M26: Covering index for fast tier lookups on chunk metadata
CREATE INDEX IF NOT EXISTS idx_chunk_metadata_ct_status_range
    ON lakets._chunk_metadata(chronotable_id, status, range_start, range_end);


-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE 23: Smart Refresh Optimizer
-- ═══════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- _touch_chunk_metadata: Statement-level trigger that updates last_modified_at
-- on the chunk metadata row whenever a partition receives writes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._touch_chunk_metadata()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE lakets._chunk_metadata
    SET last_modified_at = now()
    WHERE chunk_name = TG_TABLE_NAME;
    RETURN NULL;  -- AFTER trigger, no row modification needed
END;
$$;

-- ---------------------------------------------------------------------------
-- _get_dirty_chunks: Returns chunks with data modified since a given timestamp.
-- Used by refresh_rollup to skip unchanged chunks (chunk-skip pruning).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._get_dirty_chunks(
    p_chronotable_id  INT,
    p_since           TIMESTAMPTZ
)
RETURNS TABLE(chunk_name TEXT, range_start TIMESTAMPTZ, range_end TIMESTAMPTZ)
LANGUAGE sql STABLE
AS $$
    SELECT cm.chunk_name, cm.range_start, cm.range_end
    FROM lakets._chunk_metadata cm
    WHERE cm.chronotable_id = p_chronotable_id
      AND cm.status = 'active'
      AND (cm.last_modified_at IS NULL OR cm.last_modified_at >= p_since)
    ORDER BY cm.range_start;
$$;

-- ---------------------------------------------------------------------------
-- _detect_bucket_column: Auto-detects the time bucket column name from the
-- query output. Returns the first TIMESTAMPTZ column, or 'bucket' as fallback.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._detect_bucket_column(p_query_text TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_col RECORD;
BEGIN
    -- Create temp table from query with LIMIT 0 to inspect column types
    BEGIN
        EXECUTE format(
            'CREATE TEMP TABLE _lakets_detect_cols ON COMMIT DROP AS %s LIMIT 0',
            p_query_text
        );
    EXCEPTION WHEN OTHERS THEN
        RETURN 'bucket';  -- fallback to convention
    END;

    -- Find the first timestamp column
    FOR v_col IN
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS col_type
        FROM pg_attribute a
        WHERE a.attrelid = '_lakets_detect_cols'::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF v_col.col_type IN ('timestamp with time zone', 'timestamp without time zone') THEN
            DROP TABLE IF EXISTS _lakets_detect_cols;
            RETURN v_col.attname;
        END IF;
    END LOOP;

    DROP TABLE IF EXISTS _lakets_detect_cols;
    RETURN 'bucket';
END;
$$;

-- ---------------------------------------------------------------------------
-- _inject_time_predicate: Best-effort injection of a time predicate into the
-- inner source query for scan-level partition pruning.
-- Falls back to the original query if injection fails EXPLAIN validation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._inject_time_predicate(
    p_query_text  TEXT,
    p_time_column TEXT,
    p_dirty_from  TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_predicate TEXT;
    v_injected  TEXT;
BEGIN
    IF p_time_column IS NULL THEN
        RETURN p_query_text;
    END IF;

    v_predicate := format('%I >= %L', p_time_column, p_dirty_from);

    -- Strategy: append to existing WHERE or insert before GROUP BY
    -- Note: PostgreSQL uses \y for word boundary (not \b which is backspace in POSIX regex)
    IF p_query_text ~* '\yWHERE\y' THEN
        v_injected := regexp_replace(
            p_query_text,
            '(\yWHERE\y\s+)',
            format('\1%s AND ', v_predicate),
            'i'
        );
    ELSIF p_query_text ~* '\yGROUP\s+BY\y' THEN
        v_injected := regexp_replace(
            p_query_text,
            '(\yGROUP\s+BY\y)',
            format('WHERE %s \1', v_predicate),
            'i'
        );
    ELSE
        -- No WHERE, no GROUP BY — append WHERE at the end
        v_injected := p_query_text || format(' WHERE %s', v_predicate);
    END IF;

    -- Validate: run EXPLAIN to verify syntactic correctness
    BEGIN
        EXECUTE format('EXPLAIN %s', v_injected);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'LakeTS: predicate injection failed, falling back to outer filter. Error: %', SQLERRM;
        RETURN p_query_text;
    END;

    RETURN v_injected;
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE 24: Batch Set-Based Bucket Refresh
-- ═══════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- _refresh_buckets_batch: Refreshes all dirty buckets in 2 SQL statements
-- (1 DELETE + 1 INSERT) using ANY(array) predicates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._refresh_buckets_batch(
    p_rollup_id       INT,
    p_rollup_table    TEXT,
    p_query_text      TEXT,
    p_bucket_column   TEXT,
    p_dirty_buckets   TIMESTAMPTZ[]
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_dirty_buckets IS NULL OR array_length(p_dirty_buckets, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- Single DELETE for all dirty buckets
    EXECUTE format(
        'DELETE FROM public.%I WHERE %I = ANY($1)',
        p_rollup_table, p_bucket_column
    ) USING p_dirty_buckets;

    -- Single INSERT for all dirty buckets
    EXECUTE format(
        'INSERT INTO public.%I SELECT * FROM (%s) _q WHERE _q.%I = ANY($1)',
        p_rollup_table, p_query_text, p_bucket_column
    ) USING p_dirty_buckets;

    RETURN array_length(p_dirty_buckets, 1);
END;
$$;

-- ---------------------------------------------------------------------------
-- _refresh_buckets_chunked: Splits large dirty sets into chunks and
-- batch-refreshes each chunk. Avoids planner degradation on large arrays.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._refresh_buckets_chunked(
    p_rollup_id       INT,
    p_rollup_table    TEXT,
    p_query_text      TEXT,
    p_bucket_column   TEXT,
    p_dirty_buckets   TIMESTAMPTZ[],
    p_chunk_size      INT DEFAULT 100
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_total     INT := array_length(p_dirty_buckets, 1);
    v_offset    INT := 1;
    v_chunk     TIMESTAMPTZ[];
    v_refreshed INT := 0;
BEGIN
    IF v_total IS NULL OR v_total = 0 THEN
        RETURN 0;
    END IF;

    -- Small enough for a single batch
    IF v_total <= p_chunk_size THEN
        RETURN lakets._refresh_buckets_batch(
            p_rollup_id, p_rollup_table, p_query_text,
            p_bucket_column, p_dirty_buckets
        );
    END IF;

    -- Process in chunks
    WHILE v_offset <= v_total LOOP
        v_chunk := p_dirty_buckets[v_offset : LEAST(v_offset + p_chunk_size - 1, v_total)];

        v_refreshed := v_refreshed + lakets._refresh_buckets_batch(
            p_rollup_id, p_rollup_table, p_query_text,
            p_bucket_column, v_chunk
        );

        v_offset := v_offset + p_chunk_size;
    END LOOP;

    RETURN v_refreshed;
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE 25: RollUp DAG Orchestrator
-- ═══════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- _validate_rollup_dependencies: Trigger that validates dependency references
-- on INSERT/UPDATE to _rollup_registry. Prevents self-deps and missing refs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._validate_rollup_dependencies()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_dep_id INT;
BEGIN
    IF NEW.depends_on IS NOT NULL AND array_length(NEW.depends_on, 1) > 0 THEN
        FOREACH v_dep_id IN ARRAY NEW.depends_on LOOP
            IF NOT EXISTS (SELECT 1 FROM lakets._rollup_registry WHERE id = v_dep_id) THEN
                RAISE EXCEPTION 'RollUp dependency ID % does not exist', v_dep_id;
            END IF;
            IF v_dep_id = NEW.id THEN
                RAISE EXCEPTION 'RollUp cannot depend on itself (ID %)', v_dep_id;
            END IF;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;

-- Install the validation trigger (idempotent)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_validate_rollup_deps'
          AND tgrelid = 'lakets._rollup_registry'::regclass
    ) THEN
        CREATE TRIGGER trg_validate_rollup_deps
            BEFORE INSERT OR UPDATE ON lakets._rollup_registry
            FOR EACH ROW
            EXECUTE FUNCTION lakets._validate_rollup_dependencies();
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- _build_rollup_dag: Topological sort of the RollUp dependency graph.
-- Returns an ordered array of rollup IDs (dependencies first).
-- Raises exception on circular dependencies.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._build_rollup_dag(
    p_root_ids INT[] DEFAULT NULL
)
RETURNS INT[]
LANGUAGE plpgsql
AS $$
DECLARE
    v_all_ids   INT[];
    v_ordered   INT[] := '{}';
    v_queue     INT[] := '{}';
    v_in_deg    INT[];
    v_id        INT;
    v_dep_id    INT;
    v_idx       INT;
    v_dep_idx   INT;
    v_deps      INT[];
    v_processed INT := 0;
BEGIN
    -- Gather all RollUp IDs in scope
    IF p_root_ids IS NULL THEN
        SELECT array_agg(id ORDER BY id) INTO v_all_ids
        FROM lakets._rollup_registry;
    ELSE
        -- Expand: include roots + all their transitive dependencies
        WITH RECURSIVE dep_tree AS (
            SELECT id, depends_on
            FROM lakets._rollup_registry
            WHERE id = ANY(p_root_ids)
            UNION
            SELECT r.id, r.depends_on
            FROM lakets._rollup_registry r
            JOIN dep_tree dt ON r.id = ANY(dt.depends_on)
        )
        SELECT array_agg(DISTINCT id ORDER BY id) INTO v_all_ids FROM dep_tree;
    END IF;

    IF v_all_ids IS NULL OR array_length(v_all_ids, 1) IS NULL THEN
        RETURN '{}';
    END IF;

    -- Compute in-degrees (how many dependencies each node has within the set)
    v_in_deg := array_fill(0, ARRAY[array_length(v_all_ids, 1)]);

    FOR v_idx IN 1..array_length(v_all_ids, 1) LOOP
        SELECT depends_on INTO v_deps
        FROM lakets._rollup_registry
        WHERE id = v_all_ids[v_idx];

        IF v_deps IS NOT NULL THEN
            FOREACH v_dep_id IN ARRAY v_deps LOOP
                -- Only count deps within our set
                v_dep_idx := array_position(v_all_ids, v_dep_id);
                IF v_dep_idx IS NOT NULL THEN
                    v_in_deg[v_idx] := v_in_deg[v_idx] + 1;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- Seed queue with nodes that have zero in-degree
    FOR v_idx IN 1..array_length(v_all_ids, 1) LOOP
        IF v_in_deg[v_idx] = 0 THEN
            v_queue := array_append(v_queue, v_idx);
        END IF;
    END LOOP;

    -- Kahn's algorithm
    WHILE array_length(v_queue, 1) > 0 LOOP
        v_idx := v_queue[1];
        v_queue := v_queue[2:];
        v_ordered := array_append(v_ordered, v_all_ids[v_idx]);
        v_processed := v_processed + 1;

        -- For each node that depends on v_all_ids[v_idx], decrement in-degree
        FOR v_dep_idx IN 1..array_length(v_all_ids, 1) LOOP
            SELECT depends_on INTO v_deps
            FROM lakets._rollup_registry
            WHERE id = v_all_ids[v_dep_idx];

            IF v_deps IS NOT NULL AND v_all_ids[v_idx] = ANY(v_deps) THEN
                v_in_deg[v_dep_idx] := v_in_deg[v_dep_idx] - 1;
                IF v_in_deg[v_dep_idx] = 0 THEN
                    v_queue := array_append(v_queue, v_dep_idx);
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    -- Cycle detection
    IF v_processed != array_length(v_all_ids, 1) THEN
        RAISE EXCEPTION 'Circular dependency detected in RollUp DAG. Processed % of % nodes.',
            v_processed, array_length(v_all_ids, 1);
    END IF;

    RETURN v_ordered;
END;
$$;

-- ---------------------------------------------------------------------------
-- refresh_rollup_cascade: Refreshes all RollUps in dependency order.
-- If p_name is NULL, refreshes ALL RollUps. Otherwise refreshes the named
-- RollUp and all its transitive dependencies.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.refresh_rollup_cascade(
    p_name TEXT DEFAULT NULL
)
RETURNS TABLE(rollup_name TEXT, refreshed BOOLEAN, refresh_ms FLOAT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_root_ids  INT[];
    v_dag       INT[];
    v_id        INT;
    v_rname     TEXT;
    v_start     TIMESTAMPTZ;
    v_result    BOOLEAN;
BEGIN
    IF p_name IS NOT NULL THEN
        SELECT ARRAY[id] INTO v_root_ids
        FROM lakets._rollup_registry WHERE name = p_name;
        IF v_root_ids IS NULL THEN
            RAISE EXCEPTION 'RollUp % not found', p_name;
        END IF;
    END IF;

    v_dag := lakets._build_rollup_dag(v_root_ids);

    FOREACH v_id IN ARRAY v_dag LOOP
        SELECT r.name INTO v_rname
        FROM lakets._rollup_registry r WHERE r.id = v_id;

        v_start := clock_timestamp();
        v_result := lakets.refresh_rollup(v_rname);

        rollup_name := v_rname;
        refreshed := v_result;
        refresh_ms := extract(epoch FROM clock_timestamp() - v_start) * 1000;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_rollup_dag: Human-readable DAG visualization.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_rollup_dag()
RETURNS TABLE(
    rollup_name     TEXT,
    depends_on_names TEXT[],
    refresh_order   INT,
    bucket_interval INTERVAL,
    last_refreshed  TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_dag  INT[];
    v_id   INT;
    v_ord  INT := 0;
BEGIN
    v_dag := lakets._build_rollup_dag(NULL);

    FOREACH v_id IN ARRAY v_dag LOOP
        v_ord := v_ord + 1;

        SELECT
            r.name,
            (SELECT array_agg(r2.name)
             FROM lakets._rollup_registry r2
             WHERE r2.id = ANY(r.depends_on)),
            v_ord,
            r.bucket_interval,
            r.last_refreshed_at
        INTO rollup_name, depends_on_names, refresh_order, bucket_interval, last_refreshed
        FROM lakets._rollup_registry r
        WHERE r.id = v_id;

        RETURN NEXT;
    END LOOP;
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE 26: Intelligent Tier Router
-- ═══════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- _resolve_bucket_tier: Auto-detects whether a bucket's source data is in
-- the hot tier (Lakebase) or cold tier (Delta Lake) by checking chunk status.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._resolve_bucket_tier(
    p_chronotable_id  INT,
    p_bucket_start    TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        WHEN cm.status = 'active' THEN 'hot'
        WHEN cm.status = 'tiered' THEN 'cold'
        ELSE 'hot'
    END
    FROM lakets._chunk_metadata cm
    WHERE cm.chronotable_id = p_chronotable_id
      AND p_bucket_start >= cm.range_start
      AND p_bucket_start < cm.range_end
    LIMIT 1;
$$;


-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE 27: Bulk Import Invalidation
-- ═══════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- _bulk_import_invalidation: Statement-level AFTER INSERT trigger.
-- Uses REFERENCING NEW TABLE to capture the time range of all inserted rows
-- (including COPY FROM) and auto-invalidates affected RollUp buckets.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._bulk_import_invalidation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_min_time    TIMESTAMPTZ;
    v_max_time    TIMESTAMPTZ;
    v_time_col    TEXT;
    v_ct_id       INT;
    v_parent      TEXT;
    v_rollup      RECORD;
BEGIN
    -- Resolve partition parent using shared helper
    SELECT lakets._resolve_partition_parent(TG_TABLE_SCHEMA, TG_TABLE_NAME)
    INTO v_parent;

    -- Get the time column and ChronoTable ID
    SELECT cr.id, cr.time_column INTO v_ct_id, v_time_col
    FROM lakets._chronotable_registry cr
    WHERE cr.schema_name = TG_TABLE_SCHEMA
      AND cr.table_name = COALESCE(v_parent, TG_TABLE_NAME);

    IF v_time_col IS NULL THEN
        RETURN NULL;
    END IF;

    -- Find time range of inserted rows via transition table
    EXECUTE format('SELECT min(%I), max(%I) FROM _new_rows', v_time_col, v_time_col)
        INTO v_min_time, v_max_time;

    IF v_min_time IS NULL THEN
        RETURN NULL;
    END IF;

    -- Invalidate all RollUps that source from this ChronoTable
    FOR v_rollup IN
        SELECT r.id, r.name, r.bucket_interval, r.watermark
        FROM lakets._rollup_registry r
        WHERE r.source_chronotable_id = v_ct_id
    LOOP
        -- Only invalidate buckets below the watermark (above is handled by Phase 1)
        IF v_min_time < COALESCE(v_rollup.watermark, 'infinity'::timestamptz) THEN
            PERFORM lakets.invalidate_rollup_range(
                v_rollup.name,
                v_min_time,
                LEAST(v_max_time, COALESCE(v_rollup.watermark, v_max_time))
                    + v_rollup.bucket_interval
            );
        END IF;
    END LOOP;

    -- Also touch chunk metadata for chunk-skip tracking (M23)
    UPDATE lakets._chunk_metadata
    SET last_modified_at = now()
    WHERE chunk_name = TG_TABLE_NAME;

    RETURN NULL;
END;
$$;

