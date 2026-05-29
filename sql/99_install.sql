-- =============================================================================
-- LakeTS Master Installer
-- Run this file to install the complete LakeTS toolkit on a Lakebase instance.
--
-- Usage:
--   psql -h <host> -U <user> -d <database> -f 99_install.sql
--
-- Or execute each file in order via your preferred SQL client.
-- =============================================================================

-- Step 0: Version tracking and upgrade guard
\ir 00_version.sql

-- Step 1: Core schema and metadata tables
\ir 01_schema.sql

-- Step 2: ChronoTable management functions
\ir 02_chronotable.sql

-- Step 3: Time Series Functions (time_bucket, first, last, gapfill, locf, interpolate, delta, rate, histogram)
\ir 03_timeseries_functions.sql

-- Step 4: RollUp Engine (incremental time-bucketed aggregations)
\ir 04_rollup.sql

-- Step 5: Compression & tiering policies
\ir 05_compression.sql

-- Step 6: Retention policies
\ir 06_retention.sql

-- Step 7: Monitoring & metrics
\ir 07_monitoring.sql

-- Step 8: Multi-Metric ChronoTables + cardinality
\ir 08_metric_table.sql

-- Step 9: Last Value Cache
\ir 09_lvc.sql

-- Step 10: Downsampling pipeline registry
\ir 10_downsample.sql

-- Step 11: Alert rules
\ir 11_alerts.sql

-- Step 12: Bulk ingest + Prometheus ingest
\ir 12_ingest.sql

-- Step 13: Shadow sync for Lakehouse Sync
\ir 13_shadow_sync.sql

-- Step 14: RollUp Optimization — Modules 23-27
\ir 14_rollup_optimization.sql

-- Verify installation
DO $$
DECLARE v_func_count INT; v_table_count INT;
BEGIN
    SELECT count(*) INTO v_func_count
    FROM information_schema.routines WHERE routine_schema = 'lakets';

    SELECT count(*) INTO v_table_count
    FROM information_schema.tables WHERE table_schema = 'lakets';

    RAISE NOTICE 'LakeTS installed: % functions, % metadata tables',
        v_func_count, v_table_count;
END $$;
