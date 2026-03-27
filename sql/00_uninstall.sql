-- =============================================================================
-- LakeTS Uninstaller
-- Completely removes all LakeTS objects from the lakets schema.
--
-- Usage:
--   psql -h <host> -U <user> -d <database> -f sql/00_uninstall.sql
--
-- WARNING: This drops ALL LakeTS objects including metadata. User tables in
-- other schemas (public, etc.) are NOT affected.
-- =============================================================================

DO $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT version INTO v_version
    FROM lakets._version
    ORDER BY installed_at DESC LIMIT 1;

    IF v_version IS NOT NULL THEN
        RAISE NOTICE 'Uninstalling LakeTS v%...', v_version;
    ELSE
        RAISE NOTICE 'Uninstalling LakeTS (version unknown)...';
    END IF;
EXCEPTION WHEN undefined_table OR invalid_schema_name THEN
    RAISE NOTICE 'Uninstalling LakeTS (no version table found)...';
END $$;

DROP SCHEMA IF EXISTS lakets CASCADE;

DO $$
BEGIN
    RAISE NOTICE 'LakeTS uninstalled. Schema "lakets" dropped.';
END $$;
