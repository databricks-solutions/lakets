-- =============================================================================
-- LakeTS Live Demo — One-shot setup
-- Idempotent: safe to re-run. Each block drops/recreates its own state.
-- Run AFTER installing the lakets schema (dist/lakets.sql or sql/99_install.sql).
--
-- Targets a Lakebase Autoscaling project. Cold-tier replication uses Lakebase
-- CDF (lakets.enable_sync), so CDF (wal2delta) must already be enabled on the
-- lakets_cdf schema — a one-time Databricks setup. See the live-demo guide.
-- =============================================================================

\set ON_ERROR_STOP on
SET client_min_messages TO NOTICE;

-- ---------------------------------------------------------------------------
-- 0. Sanity: lakets schema must exist
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'lakets') THEN
        RAISE EXCEPTION 'lakets schema not installed. Run dist/lakets.sql first.';
    END IF;
    RAISE NOTICE '[setup] lakets schema present';
END $$;

-- ---------------------------------------------------------------------------
-- 1. Reference data: stock_assets
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stock_assets CASCADE;
CREATE TABLE stock_assets (
    symbol     TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    sector     TEXT NOT NULL,
    exchange   TEXT NOT NULL,
    base_price DOUBLE PRECISION NOT NULL,
    volatility DOUBLE PRECISION NOT NULL
);

INSERT INTO stock_assets (symbol, name, sector, exchange, base_price, volatility) VALUES
    ('AAPL',    'Apple',       'Tech',    'NASDAQ',   185.00, 0.020),
    ('MSFT',    'Microsoft',   'Tech',    'NASDAQ',   420.00, 0.018),
    ('NVDA',    'NVIDIA',      'Tech',    'NASDAQ',   880.00, 0.030),
    ('GOOGL',   'Alphabet',    'Tech',    'NASDAQ',   175.00, 0.022),
    ('AMZN',    'Amazon',      'Consumer','NASDAQ',   185.00, 0.025),
    ('TSLA',    'Tesla',       'Auto',    'NASDAQ',   200.00, 0.040),
    ('JPM',     'JPMorgan',    'Finance', 'NYSE',     210.00, 0.015),
    ('V',       'Visa',        'Finance', 'NYSE',     280.00, 0.014),
    ('BTC-USD', 'Bitcoin',     'Crypto',  'CRYPTO', 67000.00, 0.040),
    ('ETH-USD', 'Ethereum',    'Crypto',  'CRYPTO',  3500.00, 0.045);

-- ---------------------------------------------------------------------------
-- 2. Idempotent reset — tear down prior demo state in dependency order:
--    sync + LVC first (they own triggers/shadows), then rollups, then tables.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM lakets._chronotable_registry WHERE table_name = 'stock_ticks') THEN
        PERFORM lakets.disable_sync('stock_ticks');   -- drops lakets_cdf shadow + trigger
        PERFORM lakets.disable_lvc('stock_ticks');    -- drops public._lvc_stock_ticks + trigger
        RAISE NOTICE '[setup] disabled prior sync + LVC on stock_ticks';
    END IF;
END $$;

DO $$ DECLARE r RECORD; BEGIN
    FOR r IN SELECT name FROM lakets._rollup_registry WHERE name LIKE 'ohlcv_%' LOOP
        PERFORM lakets.drop_rollup(r.name);
        RAISE NOTICE '[setup] dropped prior rollup: %', r.name;
    END LOOP;
END $$;

-- Belt-and-suspenders for any orphaned rollup tables/views from older runs.
DROP VIEW  IF EXISTS public._rollup_rt_ohlcv_1min  CASCADE;
DROP VIEW  IF EXISTS public._rollup_rt_ohlcv_1hour CASCADE;
DROP VIEW  IF EXISTS public._rollup_rt_ohlcv_1day  CASCADE;
DROP TABLE IF EXISTS public._rollup_ohlcv_1min     CASCADE;
DROP TABLE IF EXISTS public._rollup_ohlcv_1hour    CASCADE;
DROP TABLE IF EXISTS public._rollup_ohlcv_1day     CASCADE;

-- ---------------------------------------------------------------------------
-- 3. stock_ticks → ChronoTable (1-hour chunks for demo visibility)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stock_ticks CASCADE;
DELETE FROM lakets._chronotable_registry WHERE table_name = 'stock_ticks';

CREATE TABLE stock_ticks (
    time    TIMESTAMPTZ      NOT NULL,
    symbol  TEXT             NOT NULL,
    price   DOUBLE PRECISION NOT NULL,
    volume  DOUBLE PRECISION NOT NULL
);

-- 1-hour chunks so partition creation is visible within a 30-min demo.
SELECT lakets.create_chronotable('stock_ticks', 'time', '1 hour');

-- Pre-create a window of partitions so streaming ingest always has a home.
DO $$ DECLARE v_id INT; BEGIN
    SELECT id INTO v_id FROM lakets._chronotable_registry WHERE table_name='stock_ticks';
    PERFORM lakets._ensure_partitions(p_chronotable_id := v_id,
                                      p_past_count := 2, p_future_count := 6);
END $$;

-- ---------------------------------------------------------------------------
-- 4. RollUp DAG: 1min → 1hour → 1day  (RollUps are always incremental now)
-- ---------------------------------------------------------------------------
-- Level 1: 1-minute OHLCV from raw ticks
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1min',
    p_bucket_interval => '1 minute',
    p_source_table    => 'stock_ticks',
    p_query           => $q$
        SELECT
            lakets.time_bucket('1 minute'::interval, time) AS bucket,
            symbol,
            lakets.first(price, time) AS open,
            max(price)                AS high,
            min(price)                AS low,
            lakets.last(price, time)  AS close,
            sum(volume)               AS volume,
            count(*)                  AS tick_count
        FROM stock_ticks
        GROUP BY bucket, symbol
    $q$
);

-- Level 2: 1-hour OHLCV from the 1-minute rollup
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1hour',
    p_bucket_interval => '1 hour',
    p_source_table    => 'stock_ticks',
    p_depends_on      => ARRAY['ohlcv_1min'],
    p_query           => $q$
        SELECT
            lakets.time_bucket('1 hour'::interval, bucket) AS bucket,
            symbol,
            lakets.first(open, bucket) AS open,
            max(high)                  AS high,
            min(low)                   AS low,
            lakets.last(close, bucket) AS close,
            sum(volume)                AS volume
        FROM public._rollup_ohlcv_1min
        GROUP BY lakets.time_bucket('1 hour'::interval, bucket), symbol
    $q$
);

-- Level 3: 1-day OHLCV from the 1-hour rollup
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1day',
    p_bucket_interval => '1 day',
    p_source_table    => 'stock_ticks',
    p_depends_on      => ARRAY['ohlcv_1hour'],
    p_query           => $q$
        SELECT
            lakets.time_bucket('1 day'::interval, bucket) AS bucket,
            symbol,
            lakets.first(open, bucket) AS open,
            max(high)                  AS high,
            min(low)                   AS low,
            lakets.last(close, bucket) AS close,
            sum(volume)                AS volume
        FROM public._rollup_ohlcv_1hour
        GROUP BY lakets.time_bucket('1 day'::interval, bucket), symbol
    $q$
);

-- Install invalidation triggers so incoming writes populate the dirty log.
SELECT lakets.enable_rollup_invalidation('ohlcv_1min');

-- Demo cadence: default refresh_lag is 1 hour (production-sensible). The demo
-- refreshes every minute, so drop the lag to 0s and let every cascade run.
UPDATE lakets._rollup_registry
SET refresh_lag = '0 seconds'
WHERE name IN ('ohlcv_1min', 'ohlcv_1hour', 'ohlcv_1day');

-- ---------------------------------------------------------------------------
-- 5. Last Value Cache — sub-10ms latest price per symbol
-- ---------------------------------------------------------------------------
SELECT lakets.enable_lvc(
    p_table_name    => 'stock_ticks',
    p_key_columns   => ARRAY['symbol'],
    p_value_columns => ARRAY['price', 'volume']
);

-- ---------------------------------------------------------------------------
-- 6. Tiered retention policy
--    tier_after : age at which CDF is expected to have flushed the chunk to UC
--    drop_after : age at which the hot Lakebase partition is dropped (tiering job)
-- ---------------------------------------------------------------------------
DO $$ DECLARE v_id INT; BEGIN
    SELECT id INTO v_id FROM lakets._chronotable_registry WHERE table_name='stock_ticks';
    DELETE FROM lakets._policy_registry
    WHERE chronotable_id = v_id AND policy_type IN ('retention','tiered_retention');
END $$;

SELECT lakets.add_tiered_retention_policy(
    p_table_name => 'stock_ticks',
    p_tier_after => '10 minutes',
    p_drop_after => '60 minutes'
);

-- ---------------------------------------------------------------------------
-- 7. Unity Catalog sync via Lakebase CDF (Path A)
--    enable_sync() creates the unpartitioned shadow in lakets_cdf and a
--    true-mirror trigger. CDF (wal2delta) on the lakets_cdf schema replicates
--    it to the Unity Catalog Managed Table — no per-table UI step. The tiering
--    job only drops a hot partition once CDF has flushed it (durability gate).
-- ---------------------------------------------------------------------------
SELECT lakets.enable_sync('stock_ticks');

-- ---------------------------------------------------------------------------
-- 8. Pre-demo state reset — invalidation log + LVC start empty so the
--    audience watches them fill from zero.
-- ---------------------------------------------------------------------------
TRUNCATE lakets._rollup_invalidation_log;

DO $$ DECLARE t RECORD; BEGIN
    FOR t IN
        SELECT schemaname, tablename FROM pg_tables
        WHERE schemaname='public' AND tablename LIKE '\_lvc\_%' ESCAPE '\'
    LOOP
        EXECUTE format('TRUNCATE %I.%I', t.schemaname, t.tablename);
        RAISE NOTICE '[setup] truncated LVC cache %.%', t.schemaname, t.tablename;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 9. Summary
-- ---------------------------------------------------------------------------
\echo '--- ChronoTable registry ---'
SELECT id, schema_name, table_name, time_column, chunk_interval
FROM lakets._chronotable_registry;

\echo '--- Partitions for stock_ticks ---'
SELECT chunk_name, range_start, range_end, status
FROM lakets.show_chunks('stock_ticks')
ORDER BY range_start
LIMIT 12;

\echo '--- RollUp DAG (refresh order) ---'
SELECT rollup_name, depends_on_names, refresh_order, bucket_interval
FROM lakets.show_rollup_dag()
ORDER BY refresh_order;

\echo '--- CDF shadow + LVC + invalidation ---'
SELECT 'cdf_shadow' AS kind, COUNT(*) AS rows FROM lakets_cdf._shadow_stock_ticks
UNION ALL
SELECT 'lvc',        COUNT(*)         FROM public._lvc_stock_ticks
UNION ALL
SELECT 'invalidation', COUNT(*)       FROM lakets._rollup_invalidation_log;

\echo '--- Retention policy ---'
SELECT policy_type, tier_after, drop_after, enabled
FROM lakets.show_retention_policy('stock_ticks');

\echo '[setup] DONE. Start the stream_ticks job to begin ingesting data.'
