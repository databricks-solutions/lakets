-- =============================================================================
-- LakeTS RollUp Engine
-- Incrementally-maintained time-bucketed aggregations over ChronoTables.
-- Backed by regular tables (not materialized views) for surgical per-bucket
-- refresh. Supports hot-tier (Lakebase) and cold-tier (Delta Lake) data.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- create_rollup: Creates a RollUp table with initial data load.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_rollup(
    p_name            TEXT,
    p_query           TEXT,
    p_bucket_interval INTERVAL DEFAULT '1 hour',
    p_source_table    TEXT     DEFAULT NULL,
    p_source_schema   TEXT     DEFAULT 'public',
    p_depends_on      TEXT[]   DEFAULT '{}'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rollup_id INT;
    v_chronotable_id INT;
    v_rollup_table TEXT;
    v_rt_view TEXT;
    v_idx_cols TEXT := '';
    v_col RECORD;
    v_watermark TIMESTAMPTZ;
    v_bucket_col TEXT;
    v_time_col TEXT;
    v_dep_ids INT[] := '{}';
    v_dep_name TEXT;
    v_dep_id INT;
BEGIN
    IF EXISTS (SELECT 1 FROM lakets._rollup_registry WHERE name = p_name) THEN
        RAISE EXCEPTION 'RollUp % already exists', p_name;
    END IF;

    IF p_source_table IS NOT NULL THEN
        SELECT id, time_column INTO v_chronotable_id, v_time_col
        FROM lakets._chronotable_registry
        WHERE schema_name = p_source_schema AND table_name = p_source_table;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source table %.% is not a registered ChronoTable',
                p_source_schema, p_source_table;
        END IF;
    END IF;

    -- Resolve depends_on names to IDs (M25)
    IF p_depends_on IS NOT NULL AND array_length(p_depends_on, 1) > 0 THEN
        FOREACH v_dep_name IN ARRAY p_depends_on LOOP
            SELECT id INTO v_dep_id FROM lakets._rollup_registry WHERE name = v_dep_name;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Dependency RollUp % not found', v_dep_name;
            END IF;
            v_dep_ids := array_append(v_dep_ids, v_dep_id);
        END LOOP;
    END IF;

    v_rollup_table := '_rollup_' || p_name;
    v_rt_view := '_rollup_rt_' || p_name;

    -- Create table with initial data load
    EXECUTE format('CREATE TABLE public.%I AS %s', v_rollup_table, p_query);

    -- Auto-detect bucket column (M27)
    v_bucket_col := lakets._detect_bucket_column(p_query);

    -- Build unique index on ALL columns (supports UPSERT and dedup)
    FOR v_col IN
        SELECT a.attname FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public' AND c.relname = v_rollup_table
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF v_idx_cols != '' THEN v_idx_cols := v_idx_cols || ', '; END IF;
        v_idx_cols := v_idx_cols || format('%I', v_col.attname);
    END LOOP;

    IF v_idx_cols != '' THEN
        EXECUTE format('CREATE UNIQUE INDEX %I ON public.%I (%s)',
            'idx_' || v_rollup_table || '_unique', v_rollup_table, v_idx_cols);
    END IF;

    -- Read initial watermark using detected bucket column
    EXECUTE format('SELECT max(%I) FROM public.%I', v_bucket_col, v_rollup_table)
        INTO v_watermark;

    -- Register with new columns
    INSERT INTO lakets._rollup_registry
        (name, source_chronotable_id, rollup_table, realtime_view,
         bucket_interval, query_text, watermark, last_refreshed_at,
         bucket_column, source_time_column, depends_on)
    VALUES (p_name, v_chronotable_id, v_rollup_table, v_rt_view,
            p_bucket_interval, p_query, v_watermark, now(),
            v_bucket_col, v_time_col, v_dep_ids)
    RETURNING id INTO v_rollup_id;

    RETURN v_rollup_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- refresh_rollup: Incremental or full refresh of a RollUp.
-- Returns TRUE if refreshed, FALSE if skipped (refresh_lag).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.refresh_rollup(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_dirty_from TIMESTAMPTZ;
    v_new_watermark TIMESTAMPTZ;
    v_bucket_col TEXT;
    v_query TEXT;
    v_dirty_buckets TIMESTAMPTZ[];
BEGIN
    SELECT r.*, cr.time_column
    INTO v_rec
    FROM lakets._rollup_registry r
    LEFT JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
    WHERE r.name = p_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_name;
    END IF;

    -- Serialize concurrent refresh per rollup via advisory lock
    IF NOT pg_try_advisory_xact_lock('lakets._rollup_registry'::regclass::oid::int, v_rec.id) THEN
        RAISE NOTICE 'refresh_rollup: % is already being refreshed by another session, skipping', p_name;
        RETURN FALSE;
    END IF;

    -- Honor refresh_lag: skip if refreshed too recently
    IF v_rec.last_refreshed_at IS NOT NULL
       AND v_rec.refresh_lag IS NOT NULL
       AND (v_rec.last_refreshed_at + v_rec.refresh_lag) > now() THEN
        RETURN FALSE;
    END IF;

    -- Use detected bucket column or default (M27)
    v_bucket_col := COALESCE(v_rec.bucket_column, 'bucket');

    IF v_rec.refresh_mode = 'full' THEN
        -- Full mode: TRUNCATE + re-INSERT
        EXECUTE format('TRUNCATE public.%I', v_rec.rollup_table);
        EXECUTE format('INSERT INTO public.%I %s', v_rec.rollup_table, v_rec.query_text);
    ELSE
        -- Incremental mode: only re-compute dirty window
        v_dirty_from := COALESCE(v_rec.watermark, '-infinity'::timestamptz)
                        - v_rec.bucket_interval;

        -- Phase 1: Watermark-based refresh (current window)
        -- Attempt predicate injection for scan-level pruning (M23)
        IF COALESCE(v_rec.predicate_injection, TRUE) AND v_rec.source_time_column IS NOT NULL THEN
            v_query := lakets._inject_time_predicate(
                v_rec.query_text, v_rec.source_time_column, v_dirty_from
            );
        ELSE
            v_query := v_rec.query_text;
        END IF;

        EXECUTE format('DELETE FROM public.%I WHERE %I >= %L',
            v_rec.rollup_table, v_bucket_col, v_dirty_from);

        EXECUTE format(
            'INSERT INTO public.%I SELECT * FROM (%s) _q WHERE _q.%I >= %L',
            v_rec.rollup_table, v_query, v_bucket_col, v_dirty_from
        );

        -- Phase 2: Batch refresh of hot-tier invalidation log entries (M24)
        SELECT array_agg(DISTINCT bucket_start ORDER BY bucket_start)
        INTO v_dirty_buckets
        FROM lakets._rollup_invalidation_log
        WHERE rollup_id = v_rec.id
          AND tier = 'hot'
          AND bucket_start < v_dirty_from;

        IF v_dirty_buckets IS NOT NULL AND array_length(v_dirty_buckets, 1) > 0 THEN
            PERFORM lakets._refresh_buckets_chunked(
                v_rec.id, v_rec.rollup_table, v_rec.query_text,
                v_bucket_col, v_dirty_buckets, 100
            );
        END IF;

        -- Clear only processed hot-tier entries (scoped to avoid racing with concurrent writes)
        DELETE FROM lakets._rollup_invalidation_log
        WHERE rollup_id = v_rec.id AND tier = 'hot'
          AND bucket_start < v_dirty_from;
    END IF;

    -- Advance watermark using detected bucket column
    EXECUTE format('SELECT max(%I) FROM public.%I', v_bucket_col, v_rec.rollup_table)
        INTO v_new_watermark;

    UPDATE lakets._rollup_registry
    SET watermark = COALESCE(v_new_watermark, watermark),
        last_refreshed_at = now()
    WHERE name = p_name;

    RETURN TRUE;
END;
$$;

-- ---------------------------------------------------------------------------
-- _rollup_watermark: Returns the stored watermark for a RollUp.
-- Declared STABLE so PostgreSQL caches within a single query execution.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._rollup_watermark(p_name TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
    SELECT watermark FROM lakets._rollup_registry WHERE name = p_name;
$$;

-- ---------------------------------------------------------------------------
-- create_rollup_view: Creates a real-time UNION view over a RollUp.
-- The raw_query should use lakets._rollup_watermark(name) as the boundary.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_rollup_view(
    p_name TEXT,
    p_raw_query TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_rollup_table TEXT;
    v_rt_view TEXT;
BEGIN
    SELECT rollup_table, realtime_view
    INTO v_rollup_table, v_rt_view
    FROM lakets._rollup_registry
    WHERE name = p_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_name;
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS public.%I', v_rt_view);
    EXECUTE format(
        'CREATE VIEW public.%I AS SELECT * FROM public.%I UNION ALL %s',
        v_rt_view, v_rollup_table, p_raw_query
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- drop_rollup: Drops a RollUp and all associated objects.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.drop_rollup(p_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_rollup_table TEXT;
    v_rt_view TEXT;
BEGIN
    SELECT rollup_table, realtime_view
    INTO v_rollup_table, v_rt_view
    FROM lakets._rollup_registry
    WHERE name = p_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_name;
    END IF;

    -- Tear down CDF sync (drops shadow + trigger) before the rollup table is dropped
    IF EXISTS (SELECT 1 FROM lakets._rollup_registry WHERE name = p_name AND sync_enabled = TRUE) THEN
        PERFORM lakets._disable_rollup_sync(p_name);
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS public.%I', v_rt_view);
    EXECUTE format('DROP TABLE IF EXISTS public.%I', v_rollup_table);
    DELETE FROM lakets._rollup_registry WHERE name = p_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_rollups: Lists all RollUps with status and watermark.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_rollups()
RETURNS TABLE (
    name              TEXT,
    rollup_table      TEXT,
    realtime_view     TEXT,
    bucket_interval   INTERVAL,
    refresh_mode      TEXT,
    refresh_lag       INTERVAL,
    watermark         TIMESTAMPTZ,
    last_refreshed_at TIMESTAMPTZ,
    source_table      TEXT,
    bucket_column     TEXT,
    depends_on        INT[]
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        r.name,
        r.rollup_table,
        r.realtime_view,
        r.bucket_interval,
        r.refresh_mode,
        r.refresh_lag,
        r.watermark,
        r.last_refreshed_at,
        COALESCE(cr.schema_name || '.' || cr.table_name, 'N/A'),
        COALESCE(r.bucket_column, 'bucket'),
        r.depends_on
    FROM lakets._rollup_registry r
    LEFT JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
    ORDER BY r.name;
END;
$$;

-- ---------------------------------------------------------------------------
-- _rollup_invalidation_trigger_fn: Per-row trigger that computes dirty
-- time buckets via date_bin and upserts into the invalidation log.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._rollup_invalidation_trigger_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_bucket_start TIMESTAMPTZ;
    v_parent_table TEXT;
    v_time_col TEXT;
BEGIN
    -- Resolve partition parent via shared helper
    SELECT lakets._resolve_partition_parent(TG_TABLE_SCHEMA, TG_TABLE_NAME)
    INTO v_parent_table;

    -- Get time column for this ChronoTable
    SELECT cr.time_column INTO v_time_col
    FROM lakets._chronotable_registry cr
    WHERE cr.schema_name = TG_TABLE_SCHEMA
      AND cr.table_name = COALESCE(v_parent_table, TG_TABLE_NAME);

    IF v_time_col IS NULL THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    -- Find all incremental RollUps registered against this ChronoTable
    FOR v_rec IN
        SELECT r.id, r.bucket_interval
        FROM lakets._rollup_registry r
        JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
        WHERE cr.schema_name = TG_TABLE_SCHEMA
          AND cr.table_name = COALESCE(v_parent_table, TG_TABLE_NAME)
          AND r.refresh_mode = 'incremental'
    LOOP
        IF TG_OP = 'DELETE' THEN
            EXECUTE format('SELECT date_bin(%L, ($1).%I, %L::timestamptz)',
                v_rec.bucket_interval, v_time_col, '2000-01-01')
                INTO v_bucket_start USING OLD;
        ELSE
            EXECUTE format('SELECT date_bin(%L, ($1).%I, %L::timestamptz)',
                v_rec.bucket_interval, v_time_col, '2000-01-01')
                INTO v_bucket_start USING NEW;
        END IF;

        -- Upsert into invalidation log (tier = 'hot' for Lakebase mutations)
        INSERT INTO lakets._rollup_invalidation_log (rollup_id, bucket_start, tier)
        VALUES (v_rec.id, v_bucket_start, 'hot')
        ON CONFLICT (rollup_id, bucket_start) DO UPDATE
            SET invalidated_at = now(), tier = 'hot';
    END LOOP;

    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- enable_rollup_invalidation: Installs the invalidation trigger on a
-- source ChronoTable. One trigger per table handles all RollUps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.enable_rollup_invalidation(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_mode TEXT;
BEGIN
    SELECT cr.schema_name, cr.table_name, r.refresh_mode
    INTO v_schema, v_table, v_mode
    FROM lakets._rollup_registry r
    JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
    WHERE r.name = p_rollup_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_rollup_name;
    END IF;

    IF v_mode != 'incremental' THEN
        RAISE EXCEPTION 'Invalidation requires refresh_mode = incremental (current: %)', v_mode;
    END IF;

    -- Per-row trigger for UPDATE/DELETE (existing behavior)
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_rollup_invalidation '
        'AFTER UPDATE OR DELETE ON %I.%I '
        'FOR EACH ROW EXECUTE FUNCTION lakets._rollup_invalidation_trigger_fn()',
        v_schema, v_table
    );

    -- Statement-level trigger for INSERT (M27: handles COPY + multi-row INSERT)
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_rollup_bulk_invalidation '
        'AFTER INSERT ON %I.%I '
        'REFERENCING NEW TABLE AS _new_rows '
        'FOR EACH STATEMENT EXECUTE FUNCTION lakets._bulk_import_invalidation()',
        v_schema, v_table
    );

    -- M23: Install _touch_chunk_metadata on all existing partitions
    -- so chunk-skip pruning (_get_dirty_chunks) can track last_modified_at
    DECLARE
        v_part RECORD;
    BEGIN
        FOR v_part IN
            SELECT c.relname AS part_name, n.nspname AS part_schema
            FROM pg_inherits i
            JOIN pg_class c ON i.inhrelid = c.oid
            JOIN pg_class p ON i.inhparent = p.oid
            JOIN pg_namespace n ON c.relnamespace = n.oid
            JOIN pg_namespace pn ON p.relnamespace = pn.oid
            WHERE pn.nspname = v_schema AND p.relname = v_table
        LOOP
            EXECUTE format(
                'CREATE OR REPLACE TRIGGER trg_lakets_touch_chunk '
                'AFTER INSERT ON %I.%I '
                'FOR EACH STATEMENT EXECUTE FUNCTION lakets._touch_chunk_metadata()',
                v_part.part_schema, v_part.part_name
            );
        END LOOP;
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- disable_rollup_invalidation: Removes invalidation trigger if no other
-- RollUps on the same source table need it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.disable_rollup_invalidation(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_rollup_id INT;
    v_other_count INT;
BEGIN
    SELECT cr.schema_name, cr.table_name, r.id
    INTO v_schema, v_table, v_rollup_id
    FROM lakets._rollup_registry r
    JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
    WHERE r.name = p_rollup_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_rollup_name;
    END IF;

    -- Acquire advisory lock to prevent racing with refresh_rollup
    PERFORM pg_advisory_xact_lock('lakets._rollup_registry'::regclass::oid::int, v_rollup_id);

    -- Clear invalidation log entries for this RollUp
    DELETE FROM lakets._rollup_invalidation_log WHERE rollup_id = v_rollup_id;

    -- Check if other incremental RollUps on the same source table still need the trigger
    SELECT count(*) INTO v_other_count
    FROM lakets._rollup_registry r
    JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
    WHERE cr.schema_name = v_schema AND cr.table_name = v_table
      AND r.name != p_rollup_name
      AND r.refresh_mode = 'incremental';

    IF v_other_count = 0 THEN
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_lakets_rollup_invalidation ON %I.%I',
            v_schema, v_table
        );
        -- Also drop statement-level trigger (M27)
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_lakets_rollup_bulk_invalidation ON %I.%I',
            v_schema, v_table
        );
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- invalidate_rollup_range: Manually marks a time range as dirty.
-- Use for bulk imports (COPY bypasses triggers) or cold-tier corrections.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.invalidate_rollup_range(
    p_name TEXT,
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ,
    p_tier TEXT DEFAULT NULL  -- NULL = auto-detect from chunk metadata (M26)
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_bucket TIMESTAMPTZ;
    v_tier TEXT;
    v_count INT := 0;
BEGIN
    SELECT r.id, r.bucket_interval, r.source_chronotable_id
    INTO v_rec
    FROM lakets._rollup_registry r WHERE r.name = p_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found', p_name;
    END IF;

    -- Generate all bucket_start values in the range
    FOR v_bucket IN
        SELECT generate_series(
            date_bin(v_rec.bucket_interval, p_from, '2000-01-01'::timestamptz),
            date_bin(v_rec.bucket_interval, p_to, '2000-01-01'::timestamptz),
            v_rec.bucket_interval
        )
    LOOP
        -- Auto-detect tier if not specified (M26)
        IF p_tier IS NULL THEN
            v_tier := COALESCE(
                lakets._resolve_bucket_tier(v_rec.source_chronotable_id, v_bucket),
                'hot'
            );
        ELSE
            v_tier := p_tier;
        END IF;

        INSERT INTO lakets._rollup_invalidation_log (rollup_id, bucket_start, tier)
        VALUES (v_rec.id, v_bucket, v_tier)
        ON CONFLICT (rollup_id, bucket_start) DO UPDATE
            SET invalidated_at = now(), tier = v_tier;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;
