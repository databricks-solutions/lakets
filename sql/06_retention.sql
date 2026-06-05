-- =============================================================================
-- LakeTS Retention Policies
-- Drops aged Lakebase partitions once they are durable in the Unity Catalog
-- cold tier (fail-closed, with a p_force override). Never deletes from UC.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- add_retention_policy: Auto-drops Lakebase partitions older than interval.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.add_retention_policy(
    p_table_name TEXT,
    p_drop_after INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_policy_id INT;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    IF EXISTS (
        SELECT 1 FROM lakets._policy_registry
        WHERE chronotable_id = v_chronotable_id AND policy_type = 'retention'
    ) THEN
        RAISE EXCEPTION 'Retention policy already exists for %.%',
            p_schema_name, p_table_name;
    END IF;

    INSERT INTO lakets._policy_registry
        (chronotable_id, policy_type, config, enabled)
    VALUES (v_chronotable_id, 'retention',
            jsonb_build_object('drop_after', p_drop_after::TEXT), TRUE)
    RETURNING id INTO v_policy_id;

    UPDATE lakets._chronotable_registry
    SET retention_interval = p_drop_after
    WHERE id = v_chronotable_id;

    RETURN v_policy_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- add_tiered_retention_policy: two horizons for the Lakebase (hot) copy —
-- validate-and-flag the chunk as durable in UC after tier_after (tiering job),
-- then drop the Lakebase partition after drop_after (retention job). The Unity
-- Catalog copy is retained; LakeTS never deletes from the cold tier.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.add_tiered_retention_policy(
    p_table_name TEXT,
    p_tier_after INTERVAL,
    p_drop_after INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_policy_id INT;
BEGIN
    SELECT id INTO v_chronotable_id
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    IF p_tier_after >= p_drop_after THEN
        RAISE EXCEPTION 'tier_after (%) must be less than drop_after (%)',
            p_tier_after, p_drop_after;
    END IF;

    IF EXISTS (
        SELECT 1 FROM lakets._policy_registry
        WHERE chronotable_id = v_chronotable_id AND policy_type = 'tiered_retention'
    ) THEN
        RAISE EXCEPTION 'Tiered retention policy already exists for %.%',
            p_schema_name, p_table_name;
    END IF;

    INSERT INTO lakets._policy_registry
        (chronotable_id, policy_type, config, enabled)
    VALUES (v_chronotable_id, 'tiered_retention',
            jsonb_build_object(
                'tier_after', p_tier_after::TEXT,
                'drop_after', p_drop_after::TEXT
            ), TRUE)
    RETURNING id INTO v_policy_id;

    RETURN v_policy_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- remove_retention_policy: Removes retention or tiered_retention policy.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.remove_retention_policy(
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
    WHERE chronotable_id = v_chronotable_id
      AND policy_type IN ('retention', 'tiered_retention');

    UPDATE lakets._chronotable_registry
    SET retention_interval = NULL
    WHERE id = v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- execute_retention: Physically drops a chunk's Lakebase partition once it is
-- older than drop_after. This is the ONLY step that removes data from Lakebase;
-- tiering (tier_chunk) merely validates and flags chunks 'tiered' beforehand.
--
-- Durability is enforced at drop time, fail-closed. A drop is gated whenever the
-- chunk's data is expected to live on in UC:
--   * CDF-synced table, OR a 'tiered_retention' policy (whose intent is a cold
--     copy): a chunk is dropped only if provably durable —
--     committed_lsn >= chunk.last_write_lsn. Otherwise it is DEFERRED and retried.
--     Gating tiered_retention by intent (not just the sync flag) means a policy
--     created before enable_sync never silently deletes un-mirrored data.
--   * Plain 'retention' on an un-synced table (no cold copy): dropped outright.
--   * p_force => TRUE bypasses the durability check and drops regardless. Use
--     only when you accept that an un-validated chunk's data may not yet be in UC.
--
-- LakeTS never deletes from the Unity Catalog tier; only the Lakebase partition
-- is removed. Called by the Databricks retention job.
-- ---------------------------------------------------------------------------
-- DROP first: the signature gained p_force, and CREATE OR REPLACE would leave
-- the old 2-arg overload in place (making execute_retention('t') ambiguous).
DROP FUNCTION IF EXISTS lakets.execute_retention(TEXT, TEXT);
CREATE OR REPLACE FUNCTION lakets.execute_retention(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public',
    p_force BOOLEAN DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_drop_after INTERVAL;
    v_synced BOOLEAN;
    v_policy_type TEXT;
    v_shadow TEXT;
    v_committed PG_LSN;
    v_cutoff TIMESTAMPTZ;
    v_gated BOOLEAN;
    v_chunk RECORD;
    v_parts TEXT[];
    v_dropped INT := 0;
BEGIN
    SELECT hr.id, (pr.config->>'drop_after')::INTERVAL,
           COALESCE(hr.sync_enabled, FALSE), pr.policy_type, hr.shadow_table_name
    INTO v_chronotable_id, v_drop_after, v_synced, v_policy_type, v_shadow
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
    WHERE hr.schema_name = p_schema_name
      AND hr.table_name = p_table_name
      AND pr.policy_type IN ('retention', 'tiered_retention')
      AND pr.enabled = TRUE;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    v_cutoff := now() - v_drop_after;
    v_committed := lakets._cdf_committed_lsn(v_shadow);  -- NULL unless STREAMING

    -- A drop is durability-gated whenever the chunk's data is expected to live on
    -- in UC: the table is CDF-synced, OR the policy is tiered_retention (whose very
    -- intent is to keep a cold copy — so we must NOT drop ungated even if the user
    -- forgot to enable_sync; we defer until it is provably durable, or forced).
    -- Only plain 'retention' on an un-synced table drops outright.
    v_gated := v_synced OR v_policy_type = 'tiered_retention';

    FOR v_chunk IN
        SELECT cm.id, cm.chunk_name, cm.last_write_lsn
        FROM lakets._chunk_metadata cm
        WHERE cm.chronotable_id = v_chronotable_id
          AND cm.status IN ('active', 'tiered')
          AND cm.range_end <= v_cutoff
        ORDER BY cm.range_start
    LOOP
        -- Durability check (skipped only when forced, or for plain retention on an
        -- un-synced table with no cold copy to protect).
        IF NOT p_force AND v_gated THEN
            IF v_committed IS NULL
               OR v_chunk.last_write_lsn IS NULL
               OR v_committed < v_chunk.last_write_lsn THEN
                RAISE NOTICE 'execute_retention: % deferred — not yet durable in UC '
                    '(pass p_force => TRUE to drop anyway)', v_chunk.chunk_name;
                CONTINUE;
            END IF;
        END IF;

        v_parts := string_to_array(v_chunk.chunk_name, '.');
        BEGIN
            IF array_length(v_parts, 1) = 2 THEN
                EXECUTE format('DROP TABLE IF EXISTS %I.%I', v_parts[1], v_parts[2]);
            ELSE
                EXECUTE format('DROP TABLE IF EXISTS %I', v_chunk.chunk_name);
            END IF;
            UPDATE lakets._chunk_metadata SET status = 'dropped' WHERE id = v_chunk.id;
            v_dropped := v_dropped + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed to drop chunk %: %', v_chunk.chunk_name, SQLERRM;
        END;
    END LOOP;

    UPDATE lakets._policy_registry
    SET last_run_at = now()
    WHERE chronotable_id = v_chronotable_id
      AND policy_type IN ('retention', 'tiered_retention');

    RETURN v_dropped;
END;
$$;

-- ---------------------------------------------------------------------------
-- show_retention_policy: Returns retention policy details.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.show_retention_policy(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    policy_id INT,
    policy_type TEXT,
    drop_after TEXT,
    tier_after TEXT,
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
        pr.policy_type,
        pr.config->>'drop_after',
        pr.config->>'tier_after',
        pr.enabled,
        pr.last_run_at
    FROM lakets._policy_registry pr
    WHERE pr.chronotable_id = v_chronotable_id
      AND pr.policy_type IN ('retention', 'tiered_retention');
END;
$$;
