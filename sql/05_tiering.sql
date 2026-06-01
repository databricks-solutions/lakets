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
-- _stamp_tiered_chunk_lsn: statement-level trigger that records the current
-- WAL position on every chunk that just received writes. Installed on the
-- ChronoTable PARENT (with a transition table) so it covers all current and
-- future partitions in one trigger and stamps ONLY the chunks actually
-- touched -- a write to today's hot chunk never advances a cold chunk's
-- watermark, which is what lets cold chunks become tier-eligible.
--
-- Why parent + transition table: a statement-level trigger on a partition does
-- not fire for inserts routed through the parent, and chunk_name is stored
-- schema-qualified, so the row->chunk mapping is recomputed here via date_bin
-- (same origin '2000-01-01' as _ensure_partitions).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._stamp_tiered_chunk_lsn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent   TEXT;
    v_ct_id    INT;
    v_time_col TEXT;
    v_interval INTERVAL;
BEGIN
    v_parent := lakets._resolve_partition_parent(TG_TABLE_SCHEMA, TG_TABLE_NAME);

    SELECT cr.id, cr.time_column, cr.chunk_interval
    INTO v_ct_id, v_time_col, v_interval
    FROM lakets._chronotable_registry cr
    WHERE cr.schema_name = TG_TABLE_SCHEMA
      AND cr.table_name = COALESCE(v_parent, TG_TABLE_NAME);

    IF v_ct_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- pg_current_wal_lsn() here is a lower bound on the writing txn's commit
    -- LSN. That imprecision is immaterial: tier_chunk only ever drops chunks
    -- whose time window ended at least p_after ago (days), by which point
    -- committed_lsn has long flushed past this mark.
    IF TG_OP = 'DELETE' THEN
        EXECUTE format(
            'UPDATE lakets._chunk_metadata cm
                SET last_write_lsn = pg_current_wal_lsn()
              WHERE cm.chronotable_id = $1
                AND cm.range_start IN (SELECT DISTINCT date_bin($2, %I, $3) FROM _old_rows)',
            v_time_col)
        USING v_ct_id, v_interval, '2000-01-01'::timestamptz;
    ELSE
        EXECUTE format(
            'UPDATE lakets._chunk_metadata cm
                SET last_write_lsn = pg_current_wal_lsn()
              WHERE cm.chronotable_id = $1
                AND cm.range_start IN (SELECT DISTINCT date_bin($2, %I, $3) FROM _new_rows)',
            v_time_col)
        USING v_ct_id, v_interval, '2000-01-01'::timestamptz;
    END IF;

    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- _install_tiering_write_tracking / _remove_tiering_write_tracking: attach or
-- detach the per-chunk write-LSN triggers on a ChronoTable parent. Three
-- triggers: PostgreSQL allows a transition table for only ONE event each, so
-- INSERT and UPDATE get separate NEW TABLE triggers and DELETE gets an OLD
-- TABLE trigger. All three call the same trigger function.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._install_tiering_write_tracking(
    p_schema_name TEXT, p_table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_tier_lsn_insert
         AFTER INSERT ON %I.%I
         REFERENCING NEW TABLE AS _new_rows
         FOR EACH STATEMENT EXECUTE FUNCTION lakets._stamp_tiered_chunk_lsn()',
        p_schema_name, p_table_name);
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_tier_lsn_update
         AFTER UPDATE ON %I.%I
         REFERENCING NEW TABLE AS _new_rows
         FOR EACH STATEMENT EXECUTE FUNCTION lakets._stamp_tiered_chunk_lsn()',
        p_schema_name, p_table_name);
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_tier_lsn_delete
         AFTER DELETE ON %I.%I
         REFERENCING OLD TABLE AS _old_rows
         FOR EACH STATEMENT EXECUTE FUNCTION lakets._stamp_tiered_chunk_lsn()',
        p_schema_name, p_table_name);
END;
$$;

CREATE OR REPLACE FUNCTION lakets._remove_tiering_write_tracking(
    p_schema_name TEXT, p_table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_tier_lsn_insert ON %I.%I',
        p_schema_name, p_table_name);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_tier_lsn_update ON %I.%I',
        p_schema_name, p_table_name);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_tier_lsn_delete ON %I.%I',
        p_schema_name, p_table_name);
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

    -- Track per-chunk write positions from now on.
    PERFORM lakets._install_tiering_write_tracking(p_schema_name, p_table_name);

    -- Backfill: stamp existing active chunks with the current WAL head as a
    -- conservative upper bound on their writes. A chunk drops only once CDF has
    -- flushed past this mark, so pre-policy data is never dropped before it is
    -- provably durable in UC. (NULL last_write_lsn is treated as "cannot prove
    -- durable" by tier_chunk, so this backfill is what makes existing chunks
    -- eligible at all.)
    UPDATE lakets._chunk_metadata
    SET last_write_lsn = pg_current_wal_lsn()
    WHERE chronotable_id = v_chronotable_id
      AND status = 'active'
      AND last_write_lsn IS NULL;

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

    PERFORM lakets._remove_tiering_write_tracking(p_schema_name, p_table_name);
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
-- provably flushed past every write to THAT chunk:
--   shadow is STREAMING  AND  chunk.last_write_lsn IS NOT NULL
--   AND  committed_lsn >= chunk.last_write_lsn.
-- The comparison is against the chunk's own recorded write position (stamped by
-- _stamp_tiered_chunk_lsn), NOT the global WAL head -- the head keeps advancing
-- from unrelated activity while a quiescent shadow's committed_lsn freezes, so a
-- head comparison would never pass for the cold chunks we want to evict.
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
    v_chunk_lsn PG_LSN;
    v_parts TEXT[];
BEGIN
    SELECT cm.chronotable_id, cm.last_write_lsn INTO v_chronotable_id, v_chunk_lsn
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

    IF v_chunk_lsn IS NULL THEN
        RAISE NOTICE 'tier_chunk: % skipped — no recorded write position (cannot prove durable)',
            p_chunk_name;
        RETURN FALSE;
    END IF;

    IF v_committed < v_chunk_lsn THEN
        RAISE NOTICE 'tier_chunk: % deferred — CDF has not flushed the chunk yet '
            '(committed=%, chunk_last_write=%)', p_chunk_name, v_committed, v_chunk_lsn;
        RETURN FALSE;
    END IF;

    -- Safe to drop: every write to this chunk is at or below committed_lsn, i.e.
    -- provably durable in the Unity Catalog Managed Table.
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
    v_max_pending_lsn PG_LSN;
    v_pending_unstamped INT;
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

        -- pending = active AND aged out. v_max_pending_lsn is the furthest WAL
        -- position CDF must flush past to clear the whole pending backlog;
        -- v_pending_unstamped counts pending chunks with no recorded position
        -- (cannot be proven durable, so they block "caught_up").
        SELECT
            count(*) FILTER (WHERE cm.status = 'active'),
            count(*) FILTER (WHERE cm.status = 'tiered'),
            count(*) FILTER (WHERE cm.status = 'active' AND cm.range_end <= now() - v_after),
            COALESCE(sum(cm.size_bytes) FILTER (
                WHERE cm.status = 'active' AND cm.range_end <= now() - v_after), 0),
            COALESCE(sum(cm.size_bytes) FILTER (WHERE cm.status = 'tiered'), 0),
            max(cm.last_write_lsn) FILTER (
                WHERE cm.status = 'active' AND cm.range_end <= now() - v_after),
            count(*) FILTER (
                WHERE cm.status = 'active' AND cm.range_end <= now() - v_after
                  AND cm.last_write_lsn IS NULL)
        INTO active_chunks, tiered_chunks, pending_chunks, reclaimable_bytes,
             reclaimed_bytes, v_max_pending_lsn, v_pending_unstamped
        FROM lakets._chunk_metadata cm
        WHERE cm.chronotable_id = r.id;

        IF v_committed IS NULL THEN
            cdf_status := CASE WHEN r.shadow IS NULL THEN 'NONE' ELSE 'SKIPPED' END;
            cdf_lag_bytes := NULL;
            caught_up := FALSE;
        ELSE
            cdf_status := 'STREAMING';
            -- How far CDF still has to flush to clear the pending backlog.
            cdf_lag_bytes := GREATEST(
                0, COALESCE(pg_wal_lsn_diff(v_max_pending_lsn, v_committed), 0))::BIGINT;
            -- Caught up iff CDF has flushed past every stamped pending chunk and
            -- no pending chunk is unstamped.
            caught_up := (v_pending_unstamped = 0)
                AND (v_max_pending_lsn IS NULL OR v_committed >= v_max_pending_lsn);
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$;
