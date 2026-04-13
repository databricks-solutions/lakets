-- =============================================================================
-- LakeTS Retention Policies
-- Automated data lifecycle management across Lakebase and Delta Lake tiers.
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
-- add_tiered_retention_policy: Tier to Delta after tier_after,
-- delete from Delta after drop_after.
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
-- execute_retention: Runs retention policy — drops expired chunks.
-- Called by the Databricks retention job.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.execute_retention(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_drop_after INTERVAL;
    v_dropped INT;
BEGIN
    SELECT hr.id, (pr.config->>'drop_after')::INTERVAL
    INTO v_chronotable_id, v_drop_after
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
    WHERE hr.schema_name = p_schema_name
      AND hr.table_name = p_table_name
      AND pr.policy_type IN ('retention', 'tiered_retention')
      AND pr.enabled = TRUE;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    SELECT lakets.drop_chunks(p_table_name, v_drop_after, p_schema_name)
    INTO v_dropped;

    -- Update policy last_run_at
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
