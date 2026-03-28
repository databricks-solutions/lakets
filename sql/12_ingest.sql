-- =============================================================================
-- LakeTS Bulk Ingest Functions
-- Server-side batch ingest for edge devices and protocol adapters.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- ingest_batch: Inserts multiple rows from a JSONB array into a ChronoTable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.ingest_batch(
    p_table_name TEXT,
    p_data JSONB,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_row JSONB;
    v_cols TEXT := '';
    v_vals TEXT := '';
    v_key TEXT;
    v_inserted INT := 0;
    v_first BOOLEAN;
BEGIN
    IF jsonb_typeof(p_data) != 'array' THEN
        RAISE EXCEPTION 'p_data must be a JSONB array';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_data) LOOP
        v_cols := '';
        v_vals := '';
        v_first := TRUE;

        FOR v_key IN SELECT * FROM jsonb_object_keys(v_row) LOOP
            IF NOT v_first THEN
                v_cols := v_cols || ', ';
                v_vals := v_vals || ', ';
            END IF;
            v_cols := v_cols || format('%I', v_key);

            -- Handle different JSON types
            IF jsonb_typeof(v_row->v_key) = 'string' THEN
                v_vals := v_vals || format('%L', v_row->>v_key);
            ELSIF jsonb_typeof(v_row->v_key) = 'null' THEN
                v_vals := v_vals || 'NULL';
            ELSE
                v_vals := v_vals || format('%L', v_row->>v_key);
            END IF;
            v_first := FALSE;
        END LOOP;

        EXECUTE format('INSERT INTO %I.%I (%s) VALUES (%s)',
            p_schema_name, p_table_name, v_cols, v_vals);
        v_inserted := v_inserted + 1;
    END LOOP;

    RETURN v_inserted;
END;
$$;

-- ---------------------------------------------------------------------------
-- ingest_prometheus: Inserts a single Prometheus-style metric.
-- Target table must have: time, metric_name, labels (JSONB), value columns.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.ingest_prometheus(
    p_table_name TEXT,
    p_metric_name TEXT,
    p_labels JSONB,
    p_value DOUBLE PRECISION,
    p_timestamp TIMESTAMPTZ DEFAULT now(),
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format(
        'INSERT INTO %I.%I (time, metric_name, labels, value) VALUES ($1, $2, $3, $4)',
        p_schema_name, p_table_name
    ) USING p_timestamp, p_metric_name, p_labels, p_value;
END;
$$;
