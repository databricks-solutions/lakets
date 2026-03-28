-- =============================================================================
-- LakeTS ChronoTable Manager
-- Functions for creating and managing time-partitioned tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- _ensure_partitions: Pre-creates partitions for a hypertable.
-- Supports both relative (past/future count) and explicit range.
-- Idempotent — skips partitions that already exist.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._ensure_partitions(
    p_chronotable_id INT,
    p_past_count INT DEFAULT 1,
    p_future_count INT DEFAULT 3,
    p_range_start TIMESTAMPTZ DEFAULT NULL,
    p_range_end TIMESTAMPTZ DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_start TIMESTAMPTZ;
    v_end TIMESTAMPTZ;
    v_partitions_created INT := 0;
    v_now TIMESTAMPTZ := now();
    v_interval INTERVAL;
    v_schema TEXT;
    v_table TEXT;
    v_rs TIMESTAMPTZ;
    v_re TIMESTAMPTZ;
BEGIN
    SELECT schema_name, table_name, chunk_interval
    INTO v_schema, v_table, v_interval
    FROM lakets._chronotable_registry
    WHERE id = p_chronotable_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hypertable with id % not found', p_chronotable_id;
    END IF;

    -- Use explicit range if provided, otherwise calculate from now
    IF p_range_start IS NOT NULL THEN
        v_rs := date_bin(v_interval, p_range_start, '2000-01-01'::timestamptz);
    ELSE
        v_rs := date_bin(v_interval, v_now, '2000-01-01'::timestamptz)
                - (v_interval * p_past_count);
    END IF;

    IF p_range_end IS NOT NULL THEN
        v_re := date_bin(v_interval, p_range_end, '2000-01-01'::timestamptz) + v_interval;
    ELSE
        v_re := date_bin(v_interval, v_now, '2000-01-01'::timestamptz)
                + (v_interval * (p_future_count + 1));
    END IF;

    v_start := v_rs;
    WHILE v_start < v_re LOOP
        v_end := v_start + v_interval;

        IF NOT EXISTS (
            SELECT 1 FROM lakets._chunk_metadata
            WHERE chronotable_id = p_chronotable_id
              AND range_start = v_start AND range_end = v_end
              AND status != 'dropped'
        ) THEN
            BEGIN
                EXECUTE format(
                    'CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                    v_schema,
                    v_table || '_' || to_char(v_start, 'YYYYMMDD_HH24MISS'),
                    v_schema, v_table, v_start, v_end
                );
                INSERT INTO lakets._chunk_metadata
                    (chronotable_id, chunk_name, range_start, range_end, status)
                VALUES (p_chronotable_id,
                        v_schema || '.' || v_table || '_' || to_char(v_start, 'YYYYMMDD_HH24MISS'),
                        v_start, v_end, 'active')
                ON CONFLICT (chronotable_id, range_start) DO NOTHING;
                v_partitions_created := v_partitions_created + 1;
            EXCEPTION WHEN duplicate_table THEN
                NULL;
            END;
        END IF;
        v_start := v_end;
    END LOOP;

    RETURN v_partitions_created;
END;
$$;

-- ---------------------------------------------------------------------------
-- create_hypertable: Converts a regular table to a time-partitioned table.
-- Scans existing data to create partitions covering the full range.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_hypertable(
    p_table_name TEXT,
    p_time_column TEXT,
    p_chunk_interval INTERVAL DEFAULT '7 days',
    p_schema_name TEXT DEFAULT 'public',
    p_if_not_exists BOOLEAN DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_col_type TEXT;
    v_is_partitioned BOOLEAN;
    v_tmp_table TEXT;
    v_col_rec RECORD;
    v_col_defs TEXT := '';
    v_min_time TIMESTAMPTZ;
    v_max_time TIMESTAMPTZ;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF FOUND THEN
        IF p_if_not_exists THEN RETURN v_chronotable_id; END IF;
        RAISE EXCEPTION 'Table %.% is already a ChronoTable (id=%)',
            p_schema_name, p_table_name, v_chronotable_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = p_schema_name AND table_name = p_table_name
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', p_schema_name, p_table_name;
    END IF;

    SELECT data_type INTO v_col_type
    FROM information_schema.columns
    WHERE table_schema = p_schema_name
      AND table_name = p_table_name
      AND column_name = p_time_column;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Column % does not exist in %.%',
            p_time_column, p_schema_name, p_table_name;
    END IF;

    IF v_col_type NOT IN (
        'timestamp with time zone', 'timestamp without time zone', 'date'
    ) THEN
        RAISE EXCEPTION 'Column % has type %, expected timestamp/timestamptz/date',
            p_time_column, v_col_type;
    END IF;

    SELECT (relkind = 'p') INTO v_is_partitioned
    FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = p_schema_name AND c.relname = p_table_name;

    IF v_is_partitioned THEN
        RAISE EXCEPTION 'Table %.% is already partitioned', p_schema_name, p_table_name;
    END IF;

    -- Detect data range for partition creation
    EXECUTE format('SELECT min(%I), max(%I) FROM %I.%I',
        p_time_column, p_time_column, p_schema_name, p_table_name)
    INTO v_min_time, v_max_time;

    -- Build column definitions
    FOR v_col_rec IN
        SELECT column_name, udt_name, is_nullable, column_default, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = p_schema_name AND table_name = p_table_name
        ORDER BY ordinal_position
    LOOP
        IF v_col_defs != '' THEN v_col_defs := v_col_defs || ', '; END IF;
        v_col_defs := v_col_defs || format('%I %s', v_col_rec.column_name, v_col_rec.udt_name);
        IF v_col_rec.character_maximum_length IS NOT NULL THEN
            v_col_defs := v_col_defs || format('(%s)', v_col_rec.character_maximum_length);
        END IF;
        IF v_col_rec.is_nullable = 'NO' THEN v_col_defs := v_col_defs || ' NOT NULL'; END IF;
        IF v_col_rec.column_default IS NOT NULL THEN
            -- Guard: reject defaults containing SQL injection patterns
            IF v_col_rec.column_default ~* '(;|--|/\*)' THEN
                RAISE EXCEPTION 'Unsafe column default detected on %: %',
                    v_col_rec.column_name, v_col_rec.column_default;
            END IF;
            v_col_defs := v_col_defs || format(' DEFAULT %s', v_col_rec.column_default);
        END IF;
    END LOOP;

    -- Rename original
    v_tmp_table := p_table_name || '_lakets_orig';
    EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', p_schema_name, p_table_name, v_tmp_table);

    -- Create partitioned table
    EXECUTE format('CREATE TABLE %I.%I (%s) PARTITION BY RANGE (%I)',
        p_schema_name, p_table_name, v_col_defs, p_time_column);

    -- Register
    INSERT INTO lakets._chronotable_registry (schema_name, table_name, time_column, chunk_interval)
    VALUES (p_schema_name, p_table_name, p_time_column, p_chunk_interval)
    RETURNING id INTO v_chronotable_id;

    -- Create partitions covering existing data + future
    IF v_min_time IS NOT NULL THEN
        PERFORM lakets._ensure_partitions(
            p_chronotable_id := v_chronotable_id,
            p_range_start := v_min_time,
            p_range_end := v_max_time + '1 day'::interval
        );
    END IF;
    PERFORM lakets._ensure_partitions(p_chronotable_id := v_chronotable_id);

    -- Copy data
    EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I',
        p_schema_name, p_table_name, p_schema_name, v_tmp_table);

    -- Index on time column
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I.%I (%I DESC)',
        'idx_' || p_table_name || '_' || p_time_column,
        p_schema_name, p_table_name, p_time_column);

    -- Drop original
    EXECUTE format('DROP TABLE %I.%I', p_schema_name, v_tmp_table);

    RETURN v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- set_chunk_interval: Changes the chunk interval for future partitions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.set_chunk_interval(
    p_table_name TEXT,
    p_chunk_interval INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE lakets._chronotable_registry
    SET chunk_interval = p_chunk_interval
    WHERE schema_name = p_schema_name AND table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_chunks: Lists partitions with metadata for a hypertable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_chunks(
    p_table_name TEXT,
    p_older_than INTERVAL DEFAULT NULL,
    p_newer_than INTERVAL DEFAULT NULL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    chunk_name TEXT,
    range_start TIMESTAMPTZ,
    range_end TIMESTAMPTZ,
    status TEXT,
    row_count BIGINT,
    size_bytes BIGINT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    RETURN QUERY
    SELECT cm.chunk_name, cm.range_start, cm.range_end,
           cm.status, cm.row_count, cm.size_bytes, cm.created_at
    FROM lakets._chunk_metadata cm
    WHERE cm.chronotable_id = v_chronotable_id
      AND cm.status != 'dropped'
      AND (p_older_than IS NULL OR cm.range_end < (now() - p_older_than))
      AND (p_newer_than IS NULL OR cm.range_start > (now() - p_newer_than))
    ORDER BY cm.range_start;
END;
$$;

-- ---------------------------------------------------------------------------
-- drop_chunks: Drops partitions older than a given interval.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.drop_chunks(
    p_table_name TEXT,
    p_older_than INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_chunk RECORD;
    v_dropped INT := 0;
    v_cutoff TIMESTAMPTZ;
    v_parts TEXT[];
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    v_cutoff := now() - p_older_than;

    FOR v_chunk IN
        SELECT cm.id, cm.chunk_name
        FROM lakets._chunk_metadata cm
        WHERE cm.chronotable_id = v_chronotable_id
          AND cm.status = 'active'
          AND cm.range_end <= v_cutoff
    LOOP
        v_parts := string_to_array(v_chunk.chunk_name, '.');
        BEGIN
            EXECUTE format('DROP TABLE IF EXISTS %I.%I', v_parts[1], v_parts[2]);
            UPDATE lakets._chunk_metadata SET status = 'dropped' WHERE id = v_chunk.id;
            v_dropped := v_dropped + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed to drop chunk %: %', v_chunk.chunk_name, SQLERRM;
        END;
    END LOOP;

    RETURN v_dropped;
END;
$$;

-- ---------------------------------------------------------------------------
-- create_chronotable: V2 alias for create_hypertable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_chronotable(
    p_table_name TEXT,
    p_time_column TEXT,
    p_chunk_interval INTERVAL DEFAULT '7 days',
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE sql
AS $$
    SELECT lakets.create_hypertable(p_table_name, p_time_column, p_chunk_interval, p_schema_name);
$$;
