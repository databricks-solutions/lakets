-- =============================================================================
-- LakeTS Multi-Metric ChronoTables
-- Tag + field model with cardinality management.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- create_metric_table: Creates a ChronoTable optimized for multi-metric data.
-- Tags are indexed TEXT columns; fields are DOUBLE PRECISION value columns.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_metric_table(
    p_table_name TEXT,
    p_tag_columns TEXT[],
    p_field_columns TEXT[],
    p_chunk_interval INTERVAL DEFAULT '1 day',
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_col_defs TEXT := 'time TIMESTAMPTZ NOT NULL';
    v_tag TEXT;
    v_field TEXT;
    v_idx_cols TEXT := '';
    v_chronotable_id INT;
BEGIN
    -- Build column definitions: tags as TEXT, fields as DOUBLE PRECISION
    FOREACH v_tag IN ARRAY p_tag_columns LOOP
        v_col_defs := v_col_defs || format(', %I TEXT NOT NULL', v_tag);
        IF v_idx_cols != '' THEN v_idx_cols := v_idx_cols || ', '; END IF;
        v_idx_cols := v_idx_cols || format('%I', v_tag);
    END LOOP;

    FOREACH v_field IN ARRAY p_field_columns LOOP
        v_col_defs := v_col_defs || format(', %I DOUBLE PRECISION', v_field);
    END LOOP;

    -- Create the table
    EXECUTE format('CREATE TABLE %I.%I (%s)', p_schema_name, p_table_name, v_col_defs);

    -- Convert to ChronoTable (partitioned by time)
    v_chronotable_id := lakets.create_chronotable(
        p_table_name, 'time', p_chunk_interval, p_schema_name
    );

    -- Create composite index for series-level queries: (tags..., time DESC)
    IF v_idx_cols != '' THEN
        EXECUTE format(
            'CREATE INDEX %I ON %I.%I (%s, time DESC)',
            'idx_' || p_table_name || '_series',
            p_schema_name, p_table_name, v_idx_cols
        );
    END IF;

    -- Create BRIN index on time for large range scans
    EXECUTE format(
        'CREATE INDEX %I ON %I.%I USING BRIN (time)',
        'idx_' || p_table_name || '_brin',
        p_schema_name, p_table_name
    );

    RETURN v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- cardinality_stats: Returns distinct value counts per tag column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.cardinality_stats(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    column_name TEXT,
    distinct_values BIGINT,
    total_rows BIGINT,
    pct_of_rows NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_col RECORD;
    v_total BIGINT;
BEGIN
    -- Get total row count
    EXECUTE format('SELECT count(*) FROM %I.%I', p_schema_name, p_table_name)
    INTO v_total;

    -- For each TEXT column (tags), count distinct values
    FOR v_col IN
        SELECT a.attname
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_type t ON a.atttypid = t.oid
        WHERE n.nspname = p_schema_name AND c.relname = p_table_name
          AND a.attnum > 0 AND NOT a.attisdropped
          AND t.typname = 'text'
        ORDER BY a.attnum
    LOOP
        RETURN QUERY EXECUTE format(
            'SELECT %L::TEXT, count(DISTINCT %I)::BIGINT, %s::BIGINT,
                    CASE WHEN %s > 0 THEN round(count(DISTINCT %I)::NUMERIC / %s * 100, 3) ELSE 0 END
             FROM %I.%I',
            v_col.attname, v_col.attname, v_total, v_total, v_col.attname, v_total,
            p_schema_name, p_table_name
        );
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- cardinality_check: Warns if combined series cardinality exceeds threshold.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.cardinality_check(
    p_table_name TEXT,
    p_max_series BIGINT DEFAULT 100000,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    status TEXT,
    combined_cardinality BIGINT,
    max_allowed BIGINT,
    tag_columns TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tag_cols TEXT := '';
    v_col RECORD;
    v_cardinality BIGINT;
BEGIN
    -- Build list of tag columns
    FOR v_col IN
        SELECT a.attname
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_type t ON a.atttypid = t.oid
        WHERE n.nspname = p_schema_name AND c.relname = p_table_name
          AND a.attnum > 0 AND NOT a.attisdropped
          AND t.typname = 'text'
        ORDER BY a.attnum
    LOOP
        IF v_tag_cols != '' THEN v_tag_cols := v_tag_cols || ', '; END IF;
        v_tag_cols := v_tag_cols || format('%I', v_col.attname);
    END LOOP;

    IF v_tag_cols = '' THEN
        RETURN QUERY SELECT 'OK'::TEXT, 0::BIGINT, p_max_series, ''::TEXT;
        RETURN;
    END IF;

    EXECUTE format(
        'SELECT count(*) FROM (SELECT DISTINCT %s FROM %I.%I) t',
        v_tag_cols, p_schema_name, p_table_name
    ) INTO v_cardinality;

    RETURN QUERY SELECT
        CASE
            WHEN v_cardinality > p_max_series THEN 'CRITICAL'
            WHEN v_cardinality > p_max_series * 0.8 THEN 'WARNING'
            ELSE 'OK'
        END,
        v_cardinality,
        p_max_series,
        v_tag_cols;
END;
$$;
