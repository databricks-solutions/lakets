-- =============================================================================
-- LakeTS Compression & Tiering Policies
-- Register policies for automatic data tiering from Lakebase to Delta Lake.
-- Actual tiering is executed by Databricks workflow jobs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- add_compression_policy: Registers a compression/tiering policy.
-- After compress_after interval, the Databricks compression job will:
--   1. Ensure data is synced to Delta via Lakehouse Sync
--   2. Optimize the Delta table (Z-ORDER / Liquid Clustering)
--   3. Drop the Lakebase partition
--   4. Update chunk metadata status to 'tiered'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.add_compression_policy(
    p_table_name TEXT,
    p_compress_after INTERVAL,
    p_segment_by TEXT DEFAULT NULL,
    p_order_by TEXT DEFAULT NULL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_policy_id INT;
    v_config JSONB;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    -- Check for existing compression policy
    IF EXISTS (
        SELECT 1 FROM lakets._policy_registry
        WHERE chronotable_id = v_chronotable_id AND policy_type = 'compression'
    ) THEN
        RAISE EXCEPTION 'Compression policy already exists for %.%',
            p_schema_name, p_table_name;
    END IF;

    v_config := jsonb_build_object(
        'compress_after', p_compress_after::TEXT,
        'segment_by', p_segment_by,
        'order_by', COALESCE(p_order_by, (
            SELECT time_column FROM lakets._chronotable_registry WHERE id = v_chronotable_id
        ) || ' DESC')
    );

    INSERT INTO lakets._policy_registry
        (chronotable_id, policy_type, config, enabled)
    VALUES (v_chronotable_id, 'compression', v_config, TRUE)
    RETURNING id INTO v_policy_id;

    -- Mark the hypertable as compression-enabled
    UPDATE lakets._chronotable_registry
    SET compression_enabled = TRUE
    WHERE id = v_chronotable_id;

    RETURN v_policy_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- compress_chunk: Marks a chunk for compression/tiering.
-- The actual tiering to Delta is done by the Databricks workflow job.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.compress_chunk(
    p_chunk_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE lakets._chunk_metadata
    SET status = 'compressed',
        compressed_at = now()
    WHERE chunk_name = p_chunk_name AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Chunk % not found or not active', p_chunk_name;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- decompress_chunk: Marks a tiered chunk for re-ingestion.
-- The actual data restoration from Delta is done by the Databricks workflow.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.decompress_chunk(
    p_chunk_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE lakets._chunk_metadata
    SET status = 'active',
        compressed_at = NULL,
        tiered_at = NULL
    WHERE chunk_name = p_chunk_name AND status IN ('compressed', 'tiered');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Chunk % not found or not compressed/tiered', p_chunk_name;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_compression_policy: Returns the compression policy for a hypertable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_compression_policy(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    policy_id INT,
    compress_after TEXT,
    segment_by TEXT,
    order_by TEXT,
    enabled BOOLEAN,
    last_run_at TIMESTAMPTZ
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
    SELECT
        pr.id,
        pr.config->>'compress_after',
        pr.config->>'segment_by',
        pr.config->>'order_by',
        pr.enabled,
        pr.last_run_at
    FROM lakets._policy_registry pr
    WHERE pr.chronotable_id = v_chronotable_id AND pr.policy_type = 'compression';
END;
$$;

-- ---------------------------------------------------------------------------
-- remove_compression_policy: Removes the compression policy.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.remove_compression_policy(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
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

    DELETE FROM lakets._policy_registry
    WHERE chronotable_id = v_chronotable_id AND policy_type = 'compression';

    UPDATE lakets._chronotable_registry
    SET compression_enabled = FALSE
    WHERE id = v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- _get_chunks_to_compress: Returns chunks eligible for compression.
-- Used by the Databricks compression job to find work.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._get_chunks_to_compress(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    chunk_id INT,
    chunk_name TEXT,
    range_start TIMESTAMPTZ,
    range_end TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_compress_after INTERVAL;
BEGIN
    SELECT hr.id, (pr.config->>'compress_after')::INTERVAL
    INTO v_chronotable_id, v_compress_after
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
    WHERE hr.schema_name = p_schema_name
      AND hr.table_name = p_table_name
      AND pr.policy_type = 'compression'
      AND pr.enabled = TRUE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT cm.id, cm.chunk_name, cm.range_start, cm.range_end
    FROM lakets._chunk_metadata cm
    WHERE cm.chronotable_id = v_chronotable_id
      AND cm.status = 'active'
      AND cm.range_end <= (now() - v_compress_after)
    ORDER BY cm.range_start;
END;
$$;
