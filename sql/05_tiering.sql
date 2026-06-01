-- =============================================================================
-- LakeTS Tiering Policies
-- A tiering policy drops cold ChronoTable partitions to reclaim Lakebase
-- storage. The data is already durable in the Unity Catalog Managed Table via
-- Lakebase CDF; tiering only evicts partitions once CDF has flushed past them.
-- Executed by the Databricks tiering job.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- _cdf_committed_lsn: returns the CDF-flushed LSN for a shadow table, but
-- ONLY if it is actively STREAMING in wal2delta.tables. Returns NULL (fail
-- closed) if the wal2delta subsystem is absent, the shadow does not exist,
-- or the table is not STREAMING (e.g. SKIPPED for missing REPLICA IDENTITY).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._cdf_committed_lsn(p_shadow_name TEXT)
RETURNS PG_LSN
LANGUAGE plpgsql
AS $$
DECLARE
    v_oid OID;
    v_lsn PG_LSN;
BEGIN
    IF to_regclass('wal2delta.tables') IS NULL THEN
        RETURN NULL;
    END IF;
    v_oid := to_regclass('lakets_cdf.' || quote_ident(p_shadow_name))::oid;
    IF v_oid IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT committed_lsn INTO v_lsn
    FROM wal2delta.tables
    WHERE table_oid = v_oid AND status = 'STREAMING';
    RETURN v_lsn;  -- NULL if no STREAMING row
END;
$$;

-- ---------------------------------------------------------------------------
-- add_tiering_policy: register a tiering policy. Chunks older than p_after are
-- eligible for eviction once CDF has flushed their data to UC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.add_tiering_policy(
    p_table_name TEXT,
    p_after INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_policy_id INT;
    v_sync_enabled BOOLEAN;
BEGIN
    SELECT id, sync_enabled INTO v_chronotable_id, v_sync_enabled
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    IF NOT COALESCE(v_sync_enabled, FALSE) THEN
        RAISE NOTICE 'Table %.% is not CDF-synced yet; tiering will not evict any '
            'partitions until enable_sync is called and CDF is streaming.',
            p_schema_name, p_table_name;
    END IF;

    -- _policy_registry has no unique constraint on (chronotable_id, policy_type),
    -- so guard with an existence check (matches the original add_compression_policy).
    IF EXISTS (
        SELECT 1 FROM lakets._policy_registry
        WHERE chronotable_id = v_chronotable_id AND policy_type = 'tiering'
    ) THEN
        RAISE EXCEPTION 'Tiering policy already exists for %.%', p_schema_name, p_table_name;
    END IF;

    INSERT INTO lakets._policy_registry (chronotable_id, policy_type, config, enabled)
    VALUES (v_chronotable_id, 'tiering', jsonb_build_object('after', p_after::TEXT), TRUE)
    RETURNING id INTO v_policy_id;

    UPDATE lakets._chronotable_registry
    SET tiering_enabled = TRUE
    WHERE id = v_chronotable_id;

    RETURN v_policy_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- remove_tiering_policy: Removes the tiering policy for a ChronoTable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.remove_tiering_policy(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_chronotable_id INT;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable', p_schema_name, p_table_name;
    END IF;

    DELETE FROM lakets._policy_registry
    WHERE chronotable_id = v_chronotable_id AND policy_type = 'tiering';

    UPDATE lakets._chronotable_registry
    SET tiering_enabled = FALSE
    WHERE id = v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_tiering_policy: Returns the tiering policy for a ChronoTable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_tiering_policy(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (policy_id INT, after TEXT, enabled BOOLEAN, last_run_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT pr.id, pr.config->>'after', pr.enabled, pr.last_run_at
    FROM lakets._policy_registry pr
    JOIN lakets._chronotable_registry hr ON hr.id = pr.chronotable_id
    WHERE hr.schema_name = p_schema_name
      AND hr.table_name = p_table_name
      AND pr.policy_type = 'tiering';
END;
$$;

-- ---------------------------------------------------------------------------
-- _get_chunks_to_tier: candidate chunks for eviction — active, older than the
-- policy 'after' interval, AND the table's shadow is STREAMING in CDF. The
-- exact per-chunk durability gate is enforced in tier_chunk at drop time.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._get_chunks_to_tier(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (chunk_id INT, chunk_name TEXT, range_start TIMESTAMPTZ, range_end TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_after INTERVAL;
    v_shadow TEXT;
BEGIN
    SELECT hr.id, (pr.config->>'after')::INTERVAL, hr.shadow_table_name
    INTO v_chronotable_id, v_after, v_shadow
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
    WHERE hr.schema_name = p_schema_name
      AND hr.table_name = p_table_name
      AND pr.policy_type = 'tiering'
      AND pr.enabled = TRUE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Hard gate: skip entirely unless the shadow is actively STREAMING.
    IF v_shadow IS NULL OR lakets._cdf_committed_lsn(v_shadow) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT cm.id, cm.chunk_name, cm.range_start, cm.range_end
    FROM lakets._chunk_metadata cm
    WHERE cm.chronotable_id = v_chronotable_id
      AND cm.status = 'active'
      AND cm.range_end <= (now() - v_after)
    ORDER BY cm.range_start;
END;
$$;

-- ---------------------------------------------------------------------------
-- tier_chunk: drop a chunk's partition and mark it tiered, but ONLY if CDF has
-- provably flushed past every write to that (quiescent) chunk:
--   shadow is STREAMING  AND  committed_lsn >= pg_current_wal_lsn().
-- Returns TRUE if dropped, FALSE if deferred (caller retries next run).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.tier_chunk(p_chunk_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_shadow TEXT;
    v_committed PG_LSN;
    v_head PG_LSN;
    v_parts TEXT[];
BEGIN
    SELECT cm.chronotable_id INTO v_chronotable_id
    FROM lakets._chunk_metadata cm
    WHERE cm.chunk_name = p_chunk_name AND cm.status = 'active';
    IF NOT FOUND THEN
        RAISE NOTICE 'tier_chunk: % not found or not active', p_chunk_name;
        RETURN FALSE;
    END IF;

    SELECT shadow_table_name INTO v_shadow
    FROM lakets._chronotable_registry WHERE id = v_chronotable_id;

    v_committed := lakets._cdf_committed_lsn(v_shadow);
    IF v_committed IS NULL THEN
        RAISE NOTICE 'tier_chunk: % skipped — shadow not STREAMING', p_chunk_name;
        RETURN FALSE;
    END IF;

    v_head := pg_current_wal_lsn();
    IF v_committed < v_head THEN
        RAISE NOTICE 'tier_chunk: % deferred — CDF behind WAL head (committed=%, head=%)',
            p_chunk_name, v_committed, v_head;
        RETURN FALSE;
    END IF;

    -- Safe to drop: every write to this quiescent chunk is below v_head <= committed.
    v_parts := string_to_array(p_chunk_name, '.');
    IF array_length(v_parts, 1) = 2 THEN
        EXECUTE format('DROP TABLE IF EXISTS %I.%I', v_parts[1], v_parts[2]);
    ELSE
        EXECUTE format('DROP TABLE IF EXISTS %I', p_chunk_name);
    END IF;

    UPDATE lakets._chunk_metadata
    SET status = 'tiered', tiered_at = now()
    WHERE chunk_name = p_chunk_name;

    RETURN TRUE;
END;
$$;

-- ---------------------------------------------------------------------------
-- untier_chunk: restore a tiered chunk's metadata to active (e.g. before a
-- backfill re-ingests the partition from UC).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.untier_chunk(p_chunk_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE lakets._chunk_metadata
    SET status = 'active', tiered_at = NULL, compressed_at = NULL
    WHERE chunk_name = p_chunk_name AND status = 'tiered';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Chunk % not found or not tiered', p_chunk_name;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_tiering_status: per-table tiering observability, including the CDF gate
-- state so deferrals are self-explaining.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_tiering_status(
    p_table_name TEXT DEFAULT NULL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    schema_name TEXT,
    table_name TEXT,
    after TEXT,
    active_chunks INT,
    tiered_chunks INT,
    pending_chunks INT,
    reclaimable_bytes BIGINT,
    reclaimed_bytes BIGINT,
    cdf_status TEXT,
    cdf_lag_bytes BIGINT,
    caught_up BOOLEAN,
    last_run_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    v_after INTERVAL;
    v_committed PG_LSN;
    v_head PG_LSN := pg_current_wal_lsn();
BEGIN
    FOR r IN
        SELECT hr.id, hr.schema_name AS sname, hr.table_name AS tname,
               hr.shadow_table_name AS shadow,
               pr.config->>'after' AS after_txt, pr.last_run_at AS lra
        FROM lakets._chronotable_registry hr
        JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
        WHERE pr.policy_type = 'tiering'
          AND (p_table_name IS NULL OR
               (hr.table_name = p_table_name AND hr.schema_name = p_schema_name))
    LOOP
        v_after := r.after_txt::INTERVAL;
        v_committed := lakets._cdf_committed_lsn(r.shadow);

        schema_name := r.sname;
        table_name := r.tname;
        after := r.after_txt;
        last_run_at := r.lra;

        SELECT
            count(*) FILTER (WHERE cm.status = 'active'),
            count(*) FILTER (WHERE cm.status = 'tiered'),
            count(*) FILTER (WHERE cm.status = 'active' AND cm.range_end <= now() - v_after),
            COALESCE(sum(cm.size_bytes) FILTER (
                WHERE cm.status = 'active' AND cm.range_end <= now() - v_after), 0),
            COALESCE(sum(cm.size_bytes) FILTER (WHERE cm.status = 'tiered'), 0)
        INTO active_chunks, tiered_chunks, pending_chunks, reclaimable_bytes, reclaimed_bytes
        FROM lakets._chunk_metadata cm
        WHERE cm.chronotable_id = r.id;

        IF v_committed IS NULL THEN
            cdf_status := CASE WHEN r.shadow IS NULL THEN 'NONE' ELSE 'SKIPPED' END;
            cdf_lag_bytes := NULL;
            caught_up := FALSE;
        ELSE
            cdf_status := 'STREAMING';
            cdf_lag_bytes := pg_wal_lsn_diff(v_head, v_committed)::BIGINT;
            caught_up := (v_committed >= v_head);
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$;
