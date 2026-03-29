-- =============================================================================
-- LakeTS Unity Catalog Integration -- Module 14
-- Auto-register and tag Delta tables written by LakeTS under Unity Catalog.
--
-- Requires: 00_schema.sql, 13_rollup_optimization.sql (applied first via 99_install.sql)
-- =============================================================================

-- Schema extension: UC registration tracking table
CREATE TABLE IF NOT EXISTS lakets._uc_registry (
    id              SERIAL PRIMARY KEY,
    rollup_name     TEXT NOT NULL,
    uc_catalog      TEXT NOT NULL,
    uc_schema       TEXT NOT NULL,
    uc_table        TEXT NOT NULL,
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_tagged_at  TIMESTAMPTZ,
    tags            JSONB NOT NULL DEFAULT '{}',
    UNIQUE(rollup_name),
    UNIQUE(uc_catalog, uc_schema, uc_table)
);

CREATE INDEX IF NOT EXISTS idx_uc_registry_rollup_name
    ON lakets._uc_registry(rollup_name);

-- ---------------------------------------------------------------------------
-- register_uc_table: Record that a RollUp Delta export has been registered
-- in Unity Catalog (called by uc_registration.py after the REST API call).
-- Returns the registry row id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.register_uc_table(
    p_rollup_name TEXT,
    p_uc_catalog  TEXT,
    p_uc_schema   TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rollup     lakets._rollup_registry%ROWTYPE;
    v_uc_table   TEXT;
    v_id         INT;
BEGIN
    SELECT * INTO v_rollup
    FROM lakets._rollup_registry
    WHERE name = p_rollup_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RollUp % not found in _rollup_registry', p_rollup_name;
    END IF;

    IF v_rollup.export_delta_table IS NULL THEN
        RAISE EXCEPTION
            'RollUp % has no export_delta_table configured; enable export first',
            p_rollup_name;
    END IF;

    -- Derive UC table name from leaf of the Delta table 3-part name
    v_uc_table := split_part(v_rollup.export_delta_table, '.', 3);
    IF v_uc_table = '' THEN
        v_uc_table := regexp_replace(p_rollup_name, '[^a-zA-Z0-9_]', '_', 'g');
    END IF;

    INSERT INTO lakets._uc_registry (rollup_name, uc_catalog, uc_schema, uc_table, registered_at)
    VALUES (p_rollup_name, p_uc_catalog, p_uc_schema, v_uc_table, now())
    ON CONFLICT (rollup_name) DO UPDATE
        SET uc_catalog    = EXCLUDED.uc_catalog,
            uc_schema     = EXCLUDED.uc_schema,
            uc_table      = EXCLUDED.uc_table,
            registered_at = now()
    RETURNING id INTO v_id;

    RAISE NOTICE 'Registered % -> %.%.%', p_rollup_name, p_uc_catalog, p_uc_schema, v_uc_table;
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- tag_uc_table: Persist UC tag metadata. Merges system tags
-- (lakets.source, lakets.version, lakets.rollup_name) with user tags.
-- User tags take precedence on key collision.
-- Returns the merged tag set.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.tag_uc_table(
    p_rollup_name TEXT,
    p_tags        JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_version     TEXT;
    v_system_tags JSONB;
    v_merged_tags JSONB;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lakets._uc_registry WHERE rollup_name = p_rollup_name) THEN
        RAISE EXCEPTION
            'RollUp % not found in _uc_registry; call register_uc_table first',
            p_rollup_name;
    END IF;

    SELECT version INTO v_version FROM lakets._version LIMIT 1;

    v_system_tags := jsonb_build_object(
        'lakets.source',      'lakets',
        'lakets.version',     COALESCE(v_version, 'unknown'),
        'lakets.rollup_name', p_rollup_name
    );

    v_merged_tags := v_system_tags || p_tags;

    UPDATE lakets._uc_registry
    SET tags           = v_merged_tags,
        last_tagged_at = now()
    WHERE rollup_name = p_rollup_name;

    RETURN v_merged_tags;
END;
$$;

-- ---------------------------------------------------------------------------
-- get_uc_registrations: Return all UC-registered exports (optional filter).
-- Used by uc_registration.py to build its work list.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.get_uc_registrations(
    p_rollup_name TEXT DEFAULT NULL
)
RETURNS TABLE (
    rollup_name    TEXT,
    uc_catalog     TEXT,
    uc_schema      TEXT,
    uc_table       TEXT,
    full_uc_name   TEXT,
    delta_table    TEXT,
    registered_at  TIMESTAMPTZ,
    last_tagged_at TIMESTAMPTZ,
    tags           JSONB
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        r.rollup_name,
        r.uc_catalog,
        r.uc_schema,
        r.uc_table,
        r.uc_catalog || '.' || r.uc_schema || '.' || r.uc_table AS full_uc_name,
        rr.export_delta_table                                     AS delta_table,
        r.registered_at,
        r.last_tagged_at,
        r.tags
    FROM lakets._uc_registry r
    JOIN lakets._rollup_registry rr ON rr.name = r.rollup_name
    WHERE p_rollup_name IS NULL OR r.rollup_name = p_rollup_name
    ORDER BY r.rollup_name;
$$;

-- ---------------------------------------------------------------------------
-- unregister_uc_table: Remove a UC registration record.
-- Does NOT drop the actual UC table in Databricks.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.unregister_uc_table(
    p_rollup_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted INT;
BEGIN
    DELETE FROM lakets._uc_registry WHERE rollup_name = p_rollup_name;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted = 0 THEN
        RAISE NOTICE 'No UC registration found for %', p_rollup_name;
        RETURN FALSE;
    END IF;
    RAISE NOTICE 'Removed UC registration for %', p_rollup_name;
    RETURN TRUE;
END;
$$;
