-- =============================================================================
-- LakeTS Downsampling Pipeline Registry
-- Metadata-only on Lakebase; execution happens on Databricks.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- create_downsample_pipeline: Registers a multi-resolution pipeline.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.create_downsample_pipeline(
    p_name TEXT,
    p_source_table TEXT,
    p_intervals INTERVAL[],
    p_retention INTERVAL[],
    p_agg_expressions TEXT[],
    p_group_by TEXT[] DEFAULT NULL,
    p_delta_catalog TEXT DEFAULT 'main',
    p_delta_schema TEXT DEFAULT 'lakets_rollups',
    p_source_schema TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id INT;
BEGIN
    IF array_length(p_intervals, 1) != array_length(p_retention, 1) THEN
        RAISE EXCEPTION 'intervals and retention arrays must have same length';
    END IF;

    IF EXISTS (SELECT 1 FROM lakets._downsample_registry WHERE name = p_name) THEN
        RAISE EXCEPTION 'Downsample pipeline % already exists', p_name;
    END IF;

    INSERT INTO lakets._downsample_registry
        (name, source_table, source_schema, intervals, retention,
         agg_expressions, group_by, delta_catalog, delta_schema)
    VALUES (p_name, p_source_table, p_source_schema, p_intervals, p_retention,
            p_agg_expressions, p_group_by, p_delta_catalog, p_delta_schema)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_downsample_pipelines: Lists all registered pipelines.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_downsample_pipelines()
RETURNS TABLE (
    name TEXT,
    source TEXT,
    intervals TEXT,
    retention TEXT,
    agg_expressions TEXT,
    delta_target TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        dr.name,
        dr.source_schema || '.' || dr.source_table,
        array_to_string(dr.intervals::TEXT[], ', '),
        array_to_string(dr.retention::TEXT[], ', '),
        array_to_string(dr.agg_expressions, ', '),
        dr.delta_catalog || '.' || dr.delta_schema
    FROM lakets._downsample_registry dr
    ORDER BY dr.name;
END;
$$;

-- ---------------------------------------------------------------------------
-- query_auto_resolution: Returns the best Delta table for a given time range.
-- Picks the finest resolution whose retention covers the requested range.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.query_auto_resolution(
    p_name TEXT,
    p_start TIMESTAMPTZ,
    p_end TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE (
    resolution INTERVAL,
    delta_table TEXT,
    covers_range BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_range INTERVAL;
    v_i INT;
BEGIN
    SELECT * INTO v_rec FROM lakets._downsample_registry WHERE name = p_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Downsample pipeline % not found', p_name;
    END IF;

    v_range := p_end - p_start;

    -- Check each resolution from finest to coarsest
    FOR v_i IN 1..array_length(v_rec.intervals, 1) LOOP
        resolution := v_rec.intervals[v_i];
        delta_table := format('%s.%s.%s_%s',
            v_rec.delta_catalog, v_rec.delta_schema,
            v_rec.source_table,
            regexp_replace(v_rec.intervals[v_i]::TEXT, ' ', '_')
        );
        covers_range := (v_range <= v_rec.retention[v_i]);
        RETURN NEXT;
    END LOOP;

    -- Also include raw source (hot data in Lakebase)
    resolution := '0 seconds'::INTERVAL;
    delta_table := v_rec.source_schema || '.' || v_rec.source_table || ' (Lakebase hot)';
    covers_range := TRUE;
    RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- drop_downsample_pipeline: Removes a pipeline from the registry.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.drop_downsample_pipeline(p_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM lakets._downsample_registry WHERE name = p_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Downsample pipeline % not found', p_name;
    END IF;
END;
$$;
