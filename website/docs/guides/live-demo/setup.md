---
title: Setup
sidebar_position: 3
---

## Step 1 — Connect with `psql`

Set the project and profile, resolve the endpoint, and mint a token to use as the
Postgres password. Use the project **ID** (lowercase, hyphenated — for example
`demo-lakets`), not its display name.

```bash
PROJECT=<your-project-id>
PROFILE=<your-cli-profile>

EP=$(databricks postgres list-endpoints \
       projects/$PROJECT/branches/production -p $PROFILE -o json \
     | jq -r '.[] | select(.status.endpoint_type=="ENDPOINT_TYPE_READ_WRITE") | .name')

HOST=$(databricks postgres get-endpoint "$EP" -p $PROFILE -o json | jq -r '.status.hosts.host')
USER=$(databricks current-user me -p $PROFILE -o json | jq -r '.userName')

export PGPASSWORD=$(databricks postgres generate-database-credential \
                      --json "{\"endpoint\":\"$EP\"}" -p $PROFILE -o json | jq -r '.token')

PG_URL="host=$HOST port=5432 dbname=databricks_postgres user=$USER sslmode=require"
```

Confirm the connection:

```bash
psql "$PG_URL" -tAc "SELECT 'connected as ' || current_user;"
```

:::tip

Some macOS Python and resolver combinations fail on very long Lakebase hostnames. If
`psql` hangs on connect, resolve the host and pass both `host` and `hostaddr`:

```bash
IP=$(dig +short "$HOST" | tail -1)
PG_URL="host=$HOST hostaddr=$IP port=5432 dbname=databricks_postgres user=$USER sslmode=require"
```

:::

---

## Step 2 — Install LakeTS

If the project does not already have the schema, install it from the repo root. The
`-q` flag keeps the output to just the install banner and a summary:

```bash
psql -q "$PG_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql
```

```text
NOTICE:  LakeTS 0.1.2: fresh install
NOTICE:  ===========================================
NOTICE:  LakeTS v0.1.2 installed successfully
NOTICE:    Functions: 86
NOTICE:    Tables:    8
NOTICE:  ===========================================
```

This creates the `lakets` schema **and** the `lakets_cdf` schema (the home for the CDF
shadow tables). LakeTS owns both — you do not create them by hand — and `lakets_cdf`
must exist before you enable CDF on it in [Step 4](./enable-cdf.md).

---

## Step 3 — Set up the demo schema

The steps below build the demo schema one query at a time, so you can run each in
`psql` and see exactly what it does. Every block is idempotent; run them in order. To
skip the walkthrough, run the whole script at once:

```bash
psql -q "$PG_URL" -v ON_ERROR_STOP=1 -f demo/live/sql/setup.sql
```

### 3.1 — Reference data

A static table of the symbols to simulate, each with a base price and volatility that
`stream_ticks` reads.

```sql
CREATE TABLE stock_assets (
    symbol     TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    sector     TEXT NOT NULL,
    exchange   TEXT NOT NULL,
    base_price DOUBLE PRECISION NOT NULL,
    volatility DOUBLE PRECISION NOT NULL
);

INSERT INTO stock_assets (symbol, name, sector, exchange, base_price, volatility) VALUES
    ('AAPL',    'Apple',     'Tech',     'NASDAQ',   185.00, 0.020),
    ('MSFT',    'Microsoft', 'Tech',     'NASDAQ',   420.00, 0.018),
    ('NVDA',    'NVIDIA',    'Tech',     'NASDAQ',   880.00, 0.030),
    ('AMZN',    'Amazon',    'Consumer', 'NASDAQ',   185.00, 0.025),
    ('TSLA',    'Tesla',     'Auto',     'NASDAQ',   200.00, 0.040),
    ('JPM',     'JPMorgan',  'Finance',  'NYSE',     210.00, 0.015),
    ('BTC-USD', 'Bitcoin',   'Crypto',   'CRYPTO', 67000.00, 0.040),
    ('ETH-USD', 'Ethereum',  'Crypto',   'CRYPTO',  3500.00, 0.045);
    -- (the full script seeds 10 symbols)
```

### 3.2 — The `stock_ticks` ChronoTable

Create a plain table, then register it as a ChronoTable; `create_chronotable` converts
it to a time-partitioned table. One-hour chunks keep partition creation visible within
a short demo.

```sql
CREATE TABLE stock_ticks (
    time    TIMESTAMPTZ      NOT NULL,
    symbol  TEXT             NOT NULL,
    price   DOUBLE PRECISION NOT NULL,
    volume  DOUBLE PRECISION NOT NULL
);

SELECT lakets.create_chronotable('stock_ticks', 'time', '1 hour');
```

Pre-create a window of partitions so the first ticks always have a home — otherwise the
stream waits for `partition_manager` to run.

```sql
SELECT lakets._ensure_partitions(
    p_chronotable_id := (SELECT id FROM lakets._chronotable_registry
                         WHERE table_name = 'stock_ticks'),
    p_past_count   := 2,
    p_future_count := 6
);
```

### 3.3 — The RollUp DAG

Three RollUps form a dependency graph — minute candles from raw ticks, hour from
minute, day from hour. `p_depends_on` wires the dependency so the cascade refreshes them
in order.

```sql
-- Level 1: minute OHLCV from raw ticks
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1min',
    p_bucket_interval => '1 minute',
    p_source_table    => 'stock_ticks',
    p_query           => $q$
        SELECT lakets.time_bucket('1 minute'::interval, time) AS bucket,
               symbol,
               lakets.first(price, time) AS open,
               max(price) AS high, min(price) AS low,
               lakets.last(price, time) AS close,
               sum(volume) AS volume, count(*) AS tick_count
        FROM stock_ticks
        GROUP BY bucket, symbol
    $q$
);

-- Level 2: hour OHLCV from the minute rollup
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1hour',
    p_bucket_interval => '1 hour',
    p_source_table    => 'stock_ticks',
    p_depends_on      => ARRAY['ohlcv_1min'],
    p_query           => $q$
        SELECT lakets.time_bucket('1 hour'::interval, bucket) AS bucket,
               symbol,
               lakets.first(open, bucket) AS open,
               max(high) AS high, min(low) AS low,
               lakets.last(close, bucket) AS close,
               sum(volume) AS volume
        FROM public._rollup_ohlcv_1min
        GROUP BY lakets.time_bucket('1 hour'::interval, bucket), symbol
    $q$
);

-- Level 3: day OHLCV from the hour rollup
SELECT lakets.create_rollup(
    p_name            => 'ohlcv_1day',
    p_bucket_interval => '1 day',
    p_source_table    => 'stock_ticks',
    p_depends_on      => ARRAY['ohlcv_1hour'],
    p_query           => $q$
        SELECT lakets.time_bucket('1 day'::interval, bucket) AS bucket,
               symbol,
               lakets.first(open, bucket) AS open,
               max(high) AS high, min(low) AS low,
               lakets.last(close, bucket) AS close,
               sum(volume) AS volume
        FROM public._rollup_ohlcv_1hour
        GROUP BY lakets.time_bucket('1 day'::interval, bucket), symbol
    $q$
);
```

Install the invalidation trigger so writes record dirty buckets, and drop the refresh
lag to zero so every scheduled cascade does work. The default lag is one hour —
production-sensible, but too slow to watch live.

```sql
SELECT lakets.enable_rollup_invalidation('ohlcv_1min');

UPDATE lakets._rollup_registry
SET refresh_lag = '0 seconds'
WHERE name IN ('ohlcv_1min', 'ohlcv_1hour', 'ohlcv_1day');
```

### 3.4 — Last Value Cache

Install the cache and trigger that keep the latest `price` and `volume` per symbol for
sub-10ms latest-state reads.

```sql
SELECT lakets.enable_lvc(
    p_table_name    => 'stock_ticks',
    p_key_columns   => ARRAY['symbol'],
    p_value_columns => ARRAY['price', 'volume']
);
```

### 3.5 — Tiered retention policy

`tier_after` is the age at which data should be in the lakehouse; `drop_after` is the
age at which the hot partition may be dropped.

```sql
SELECT lakets.add_tiered_retention_policy(
    p_table_name => 'stock_ticks',
    p_tier_after => '10 minutes',
    p_drop_after => '60 minutes'
);
```

### 3.6 — Unity Catalog sync (CDF)

Create the unpartitioned shadow in `lakets_cdf` and its mirror trigger. Lakebase CDF
then syncs that shadow to Unity Catalog, once you turn it on in [Step 4](./enable-cdf.md).

```sql
SELECT lakets.enable_sync('stock_ticks');
```

### 3.7 — Verify

```sql
SELECT * FROM lakets.show_chunks('stock_ticks') ORDER BY range_start;   -- partitions
SELECT * FROM lakets.show_rollup_dag() ORDER BY refresh_order;          -- DAG in order
SELECT * FROM lakets.show_retention_policy('stock_ticks');              -- policy
```
