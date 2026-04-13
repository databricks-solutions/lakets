-- =============================================================================
-- LakeTS Version Tracking
-- Manages install/upgrade lifecycle. Must be the first module executed.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS lakets;

CREATE TABLE IF NOT EXISTS lakets._version (
    version       TEXT        NOT NULL,
    installed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    modules       TEXT[]      NOT NULL DEFAULT '{}'
);

-- Version guard: prevents downgrades, allows reinstall and upgrade.
DO $$
DECLARE
    v_installed       TEXT;
    v_incoming        TEXT := coalesce(nullif('__LAKETS_VERSION__', '__LAKE' || 'TS_VERSION__'), '0.1.2');
    v_installed_parts INT[];
    v_incoming_parts  INT[];
BEGIN
    SELECT version INTO v_installed
    FROM lakets._version
    ORDER BY installed_at DESC
    LIMIT 1;

    -- Clean up any rows with unresolved build placeholders from prior bad installs
    DELETE FROM lakets._version WHERE version !~ '^\d+\.\d+\.\d+';

    SELECT version INTO v_installed
    FROM lakets._version
    ORDER BY installed_at DESC
    LIMIT 1;

    IF v_installed IS NULL THEN
        INSERT INTO lakets._version (version, modules)
        VALUES (v_incoming, '{}');
        RAISE NOTICE 'LakeTS %: fresh install', v_incoming;
    ELSE
        v_installed_parts := string_to_array(v_installed, '.')::INT[];
        v_incoming_parts  := string_to_array(v_incoming, '.')::INT[];

        IF v_incoming_parts < v_installed_parts THEN
            RAISE EXCEPTION 'LakeTS downgrade blocked: installed=%, incoming=%',
                v_installed, v_incoming;
        END IF;

        IF v_incoming = v_installed THEN
            UPDATE lakets._version
            SET installed_at = now()
            WHERE version = v_incoming;
            RAISE NOTICE 'LakeTS %: reinstalling (idempotent)', v_incoming;
        ELSE
            INSERT INTO lakets._version (version, modules)
            VALUES (v_incoming, '{}');
            RAISE NOTICE 'LakeTS %: upgrading from %', v_incoming, v_installed;
        END IF;
    END IF;
END $$;
