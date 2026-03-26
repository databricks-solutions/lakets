-- =============================================================================
-- LakeTS Core Schema
-- Metadata tables for hypertable management, chunk tracking, and policies.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS lakets;

-- ---------------------------------------------------------------------------
-- ChronoTable Registry: tracks all tables converted to time-partitioned tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lakets._chronotable_registry (
    id SERIAL PRIMARY KEY,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    time_column TEXT NOT NULL,
    chunk_interval INTERVAL NOT NULL DEFAULT '7 days',
    space_column TEXT,
    space_partitions INT DEFAULT 1,
    compression_enabled BOOLEAN DEFAULT FALSE,
    retention_interval INTERVAL,
    shadow_table_name TEXT,
    sync_enabled BOOLEAN DEFAULT FALSE,
    last_synced_lsn BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(schema_name, table_name)
);

-- ---------------------------------------------------------------------------
-- Chunk Metadata: tracks individual partitions (chunks) of each hypertable
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lakets._chunk_metadata (
    id SERIAL PRIMARY KEY,
    chronotable_id INT NOT NULL REFERENCES lakets._chronotable_registry(id) ON DELETE CASCADE,
    chunk_name TEXT NOT NULL,
    range_start TIMESTAMPTZ NOT NULL,
    range_end TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    row_count BIGINT,
    size_bytes BIGINT,
    compressed_at TIMESTAMPTZ,
    tiered_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT valid_status CHECK (status IN ('active', 'compressed', 'tiered', 'dropped'))
);

CREATE INDEX IF NOT EXISTS idx_chunk_metadata_hypertable
    ON lakets._chunk_metadata(chronotable_id);

CREATE INDEX IF NOT EXISTS idx_chunk_metadata_range
    ON lakets._chunk_metadata(range_start, range_end);

-- ---------------------------------------------------------------------------
-- Policy Registry: tracks compression, retention, and tiering policies
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lakets._policy_registry (
    id SERIAL PRIMARY KEY,
    chronotable_id INT NOT NULL REFERENCES lakets._chronotable_registry(id) ON DELETE CASCADE,
    policy_type TEXT NOT NULL,
    config JSONB NOT NULL DEFAULT '{}',
    enabled BOOLEAN DEFAULT TRUE,
    last_run_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT valid_policy_type CHECK (policy_type IN ('compression', 'retention', 'tiered_retention'))
);

-- ---------------------------------------------------------------------------
-- RollUp Registry: tracks all RollUps and their refresh state
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lakets._rollup_registry (
    id                    SERIAL PRIMARY KEY,
    name                  TEXT UNIQUE NOT NULL,
    source_chronotable_id INT NOT NULL REFERENCES lakets._chronotable_registry(id) ON DELETE CASCADE,
    rollup_table          TEXT NOT NULL,
    realtime_view         TEXT,
    bucket_interval       INTERVAL NOT NULL,
    refresh_mode          TEXT NOT NULL DEFAULT 'incremental',
    refresh_lag           INTERVAL DEFAULT '1 hour',
    watermark             TIMESTAMPTZ,
    query_text            TEXT NOT NULL,
    last_refreshed_at     TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT valid_refresh_mode CHECK (refresh_mode IN ('full', 'incremental'))
);

-- ---------------------------------------------------------------------------
-- RollUp Invalidation Log: tracks dirty time buckets needing re-aggregation
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lakets._rollup_invalidation_log (
    id             SERIAL PRIMARY KEY,
    rollup_id      INT NOT NULL REFERENCES lakets._rollup_registry(id) ON DELETE CASCADE,
    bucket_start   TIMESTAMPTZ NOT NULL,
    tier           TEXT NOT NULL DEFAULT 'hot',
    invalidated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_rollup_invalidation UNIQUE (rollup_id, bucket_start),
    CONSTRAINT valid_tier CHECK (tier IN ('hot', 'cold'))
);

CREATE INDEX IF NOT EXISTS idx_rollup_invalidation_rollup_id
    ON lakets._rollup_invalidation_log(rollup_id, tier, bucket_start);
