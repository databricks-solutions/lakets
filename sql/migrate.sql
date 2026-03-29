-- =============================================================================
-- LakeTS Migration Runner
-- Applies all pending migrations in version order.
--
-- Usage:
--   psql -h <host> -U <user> -d <database> -f sql/migrate.sql
--
-- The runner detects the installed version from lakets._version and applies
-- only migrations that upgrade beyond the current version. All migrations
-- are idempotent — re-running this file is safe.
-- =============================================================================

\echo 'LakeTS Migration Runner'
\echo 'Detecting installed version...'

DO $$
DECLARE
    v_current TEXT;
BEGIN
    SELECT version INTO v_current
    FROM lakets._version
    ORDER BY installed_at DESC
    LIMIT 1;

    IF v_current IS NULL THEN
        RAISE EXCEPTION
            'LakeTS is not installed. Run sql/99_install.sql first.';
    END IF;

    RAISE NOTICE 'Current LakeTS version: %', v_current;
END $$;

-- ---------------------------------------------------------------------------
-- Apply migrations in version order
-- Each migration is guarded by its own internal version check — safe to run
-- even if already applied.
-- ---------------------------------------------------------------------------

-- v0.1.0 → v0.1.1
\ir ../migrations/V010_V011_security_hardening.sql

-- v0.1.1 → v0.2.0  (add when released)
-- \ir ../migrations/V011_V020_uc_integration.sql

\echo 'Migration runner complete. Run `SELECT * FROM lakets._version ORDER BY installed_at;` to verify.'
