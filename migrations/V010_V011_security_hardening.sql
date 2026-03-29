-- =============================================================================
-- LakeTS Migration: v0.1.0 → v0.1.1
-- Security hardening, missing DDL, and CI guardrails
--
-- This migration is IDEMPOTENT. It is safe to re-run.
-- It records itself in lakets._version upon success.
--
-- Prerequisites: LakeTS v0.1.0 must be installed.
-- Apply before re-running the full install (dist/lakets.sql or 99_install.sql).
-- =============================================================================

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM lakets._version WHERE version = '0.1.0') THEN
        RAISE EXCEPTION
            'Migration V010_V011 requires LakeTS v0.1.0 to be installed. '
            'Current version: %',
            (SELECT version FROM lakets._version ORDER BY installed_at DESC LIMIT 1);
    END IF;
    IF EXISTS (SELECT 1 FROM lakets._version WHERE version = '0.1.1') THEN
        RAISE NOTICE 'Migration V010_V011 already applied (v0.1.1 present). Skipping.';
    END IF;
END $$;

-- Only run if we're on v0.1.0 and haven't applied this migration yet
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM lakets._version WHERE version = '0.1.0')
       OR EXISTS (SELECT 1 FROM lakets._version WHERE version = '0.1.1') THEN
        RETURN;
    END IF;

    RAISE NOTICE 'Applying migration V010_V011: security hardening and missing DDL';

    -- -------------------------------------------------------------------------
    -- 1. Add missing metadata tables (added in v0.1.1)
    -- -------------------------------------------------------------------------

    CREATE TABLE IF NOT EXISTS lakets._lvc_registry (
        id              SERIAL PRIMARY KEY,
        table_name      TEXT NOT NULL UNIQUE,
        key_columns     TEXT[] NOT NULL,
        value_columns   TEXT[] NOT NULL,
        cache_table     TEXT NOT NULL,
        enabled         BOOLEAN DEFAULT TRUE,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS lakets._downsample_registry (
        id              SERIAL PRIMARY KEY,
        name            TEXT NOT NULL UNIQUE,
        source_table    TEXT NOT NULL,
        resolutions     JSONB NOT NULL DEFAULT '[]',
        enabled         BOOLEAN DEFAULT TRUE,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    -- -------------------------------------------------------------------------
    -- 2. Add missing indexes (covering index for chunk metadata tier lookups)
    -- -------------------------------------------------------------------------
    CREATE INDEX IF NOT EXISTS idx_chunk_metadata_ct_status_range
        ON lakets._chunk_metadata(chronotable_id, status, range_start, range_end);

    -- -------------------------------------------------------------------------
    -- 3. Add missing columns on _rollup_registry (M23-M28)
    -- -------------------------------------------------------------------------
    ALTER TABLE lakets._rollup_registry
        ADD COLUMN IF NOT EXISTS bucket_column        TEXT    DEFAULT 'bucket',
        ADD COLUMN IF NOT EXISTS source_time_column   TEXT,
        ADD COLUMN IF NOT EXISTS predicate_injection  BOOLEAN DEFAULT TRUE,
        ADD COLUMN IF NOT EXISTS depends_on           INT[]   DEFAULT '{}',
        ADD COLUMN IF NOT EXISTS cold_query_text      TEXT,
        ADD COLUMN IF NOT EXISTS export_enabled       BOOLEAN DEFAULT FALSE,
        ADD COLUMN IF NOT EXISTS export_delta_table   TEXT,
        ADD COLUMN IF NOT EXISTS export_mode          TEXT    DEFAULT 'incremental',
        ADD COLUMN IF NOT EXISTS last_exported_at     TIMESTAMPTZ;

    -- -------------------------------------------------------------------------
    -- 4. Add last_modified_at on chunk metadata (M23 chunk-skip pruning)
    -- -------------------------------------------------------------------------
    ALTER TABLE lakets._chunk_metadata
        ADD COLUMN IF NOT EXISTS last_modified_at TIMESTAMPTZ;

    -- -------------------------------------------------------------------------
    -- 5. Record migration as applied (v0.1.1)
    -- -------------------------------------------------------------------------
    INSERT INTO lakets._version (version, installed_at, modules)
    SELECT '0.1.1', now(), modules || ARRAY['V010_V011_security_hardening']
    FROM lakets._version
    WHERE version = '0.1.0'
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'Migration V010_V011 applied successfully. LakeTS is now at v0.1.1.';
END $$;
