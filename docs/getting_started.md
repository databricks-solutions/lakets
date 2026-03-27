# Getting Started with LakeTS

LakeTS is a time series toolkit for Databricks Lakebase. It adds automatic partitioning, time series functions, incremental rollups, compression, and retention to Lakebase's native PostgreSQL — all in pure SQL.

## Prerequisites

- A Databricks workspace with Lakebase enabled
- A Lakebase instance (provisioned or autoscale)
- A PostgreSQL client (`psql`, DBeaver, or any Postgres-compatible tool)

## 1. Install LakeTS

Connect to your Lakebase instance and run the installer:

```bash
psql -h <your-lakebase-host> -U <user>@databricks.com -d <database> -f lakets/sql/99_install.sql
```

Or execute each file in order:
```sql
-- Run in your SQL client connected to Lakebase
\ir lakets/sql/00_schema.sql
\ir lakets/sql/01_hypertable.sql       -- ChronoTable management (create_chronotable alias included)
\ir lakets/sql/02_hyperfunctions.sql   -- Time series functions
\ir lakets/sql/03_rollup.sql
\ir lakets/sql/04_compression.sql
\ir lakets/sql/05_retention.sql
\ir lakets/sql/06_monitoring.sql
\ir lakets/sql/07_shadow_sync.sql
```

Verify installation:
```sql
SELECT count(*) FROM information_schema.routines WHERE routine_schema = 'lakets';
-- Should return 56
```

## 2. Create Your First ChronoTable

A **ChronoTable** is a time-partitioned table — LakeTS's core abstraction for time series data.

**Option A: Single-metric table** (simple):
```sql
CREATE TABLE metrics (
    time    TIMESTAMPTZ NOT NULL,
    device  TEXT NOT NULL,
    cpu     DOUBLE PRECISION,
    memory  DOUBLE PRECISION
);
INSERT INTO metrics
SELECT now() - (i || ' minutes')::interval, 'sensor_' || (i % 10),
       50 + 30 * sin(i::float / 100), 40 + 20 * cos(i::float / 200)
FROM generate_series(1, 10000) AS s(i);

-- Convert to ChronoTable with 1-day partitions
SELECT lakets.create_chronotable('metrics', 'time', '1 day');
```

**Option B: Multi-metric table** (InfluxDB-style with tags + fields):
```sql
-- Creates table + ChronoTable + composite index + BRIN index in one call
SELECT lakets.create_metric_table(
    'system_metrics',
    tag_columns   := ARRAY['host', 'region', 'env'],
    field_columns := ARRAY['cpu', 'memory', 'disk_io'],
    chunk_interval := '1 day'
);

INSERT INTO system_metrics (time, host, region, env, cpu, memory, disk_io)
VALUES (now(), 'web-01', 'us-west-2', 'prod', 72.5, 4096, 234.5);
```

Check the partitions:
```sql
SELECT * FROM lakets.show_chunks('metrics');
```

## 3. Query with Time Series Functions

**Time bucketing** - aggregate by arbitrary intervals:
```sql
SELECT
    lakets.time_bucket('1 hour'::interval, time) AS hour,
    device,
    avg(cpu) AS avg_cpu,
    max(memory) AS max_mem
FROM metrics
WHERE time > now() - interval '1 day'
GROUP BY 1, 2
ORDER BY 1 DESC;
```

**First and last values**:
```sql
SELECT
    device,
    lakets.first(cpu, time) AS first_reading,
    lakets.last(cpu, time) AS latest_reading
FROM metrics
GROUP BY device;
```

**Gap-filled time series** (fill missing hours):
```sql
WITH buckets AS (
    SELECT b FROM lakets.time_bucket_gapfill(
        '1 hour'::interval,
        now() - interval '1 day',
        now()
    ) b
),
hourly AS (
    SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
           avg(cpu) AS avg_cpu
    FROM metrics WHERE device = 'sensor_0'
    GROUP BY 1
)
SELECT
    b.b AS hour,
    lakets.locf(h.avg_cpu, LAG(h.avg_cpu) OVER (ORDER BY b.b)) AS cpu_filled
FROM buckets b
LEFT JOIN hourly h ON b.b = h.bucket
ORDER BY b.b;
```

**Rate of change**:
```sql
SELECT time, cpu,
       lakets.delta(cpu, LAG(cpu) OVER (ORDER BY time)) AS change,
       lakets.rate(cpu, LAG(cpu) OVER (ORDER BY time),
                   time, LAG(time) OVER (ORDER BY time)) AS rate_per_sec
FROM metrics
WHERE device = 'sensor_0'
ORDER BY time DESC
LIMIT 10;
```

## 4. Set Up RollUps (Incremental Aggregates)

Pre-compute hourly rollups that refresh incrementally (only dirty buckets are recomputed):

```sql
-- Create a RollUp (incremental by default)
SELECT lakets.create_rollup(
    'metrics_hourly',
    $$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
             count(*) AS cnt,
             round(avg(cpu)::numeric, 2) AS avg_cpu,
             round(avg(memory)::numeric, 2) AS avg_mem
      FROM metrics GROUP BY 1$$,
    '1 hour',
    'metrics'
);

-- Query pre-computed data (fast!)
SELECT * FROM _rollup_metrics_hourly ORDER BY bucket DESC LIMIT 10;

-- Add a real-time view (RollUp Table + fresh data combined)
SELECT lakets.create_rollup_view('metrics_hourly',
    $$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
             count(*) AS cnt,
             round(avg(cpu)::numeric, 2) AS avg_cpu,
             round(avg(memory)::numeric, 2) AS avg_mem
      FROM metrics
      WHERE time > lakets._rollup_watermark('metrics_hourly')
      GROUP BY 1$$);

-- Always-fresh results
SELECT * FROM _rollup_rt_metrics_hourly ORDER BY bucket DESC LIMIT 10;

-- Incremental refresh (only processes new/dirty buckets — not the entire dataset)
SELECT lakets.refresh_rollup('metrics_hourly');
-- Returns: TRUE (refreshed) or FALSE (skipped due to refresh_lag)

-- Optional: enable invalidation tracking for historical corrections
SELECT lakets.enable_rollup_invalidation('metrics_hourly');
```

## 5. RollUp Dependencies (DAG Cascade)

Build hierarchical RollUps that refresh in the correct order:

```sql
-- Create a daily RollUp that depends on the hourly one
SELECT lakets.create_rollup(
    'metrics_daily',
    $$SELECT lakets.time_bucket('1 day'::interval, bucket) AS bucket,
             sum(cnt) AS cnt,
             round(avg(avg_cpu)::numeric, 2) AS avg_cpu,
             round(avg(avg_mem)::numeric, 2) AS avg_mem
      FROM _rollup_metrics_hourly GROUP BY 1$$,
    '1 day',
    'metrics',
    p_depends_on := ARRAY['metrics_hourly']
);

-- Refresh all dependencies in topological order
SELECT * FROM lakets.refresh_rollup_cascade('metrics_daily');
-- rollup_name      | refreshed | refresh_ms
-- metrics_hourly   | true      | 12.5
-- metrics_daily    | true      | 8.3

-- View the dependency graph
SELECT * FROM lakets.show_rollup_dag();
```

## 6. Export RollUps to Delta Lake

Make RollUp Tables available to Spark, ML pipelines, and BI tools:

```sql
-- Enable export to Delta
SELECT lakets.enable_rollup_export(
    'metrics_hourly',
    'main.lakets_rollups.metrics_hourly',  -- Delta table path
    'incremental'                           -- 'full' or 'incremental'
);

-- Check export status
SELECT * FROM lakets.show_rollup_exports();

-- Disable export
SELECT lakets.disable_rollup_export('metrics_hourly');
```

The actual export is performed by the `rollup_export.py` Databricks Job, which reads export-enabled RollUps and writes to Delta.

## 7. Configure Data Lifecycle

**Compression** (tier old data to Delta Lake):
```sql
SELECT lakets.add_compression_policy('metrics', '7 days');
```

**Retention** (drop old partitions):
```sql
SELECT lakets.add_retention_policy('metrics', '30 days');
```

**Tiered retention** (tier then drop):
```sql
SELECT lakets.add_tiered_retention_policy('metrics', '7 days', '90 days');
```

## 8. Monitor Your System

```sql
-- All operational metrics
SELECT * FROM lakets.lakets_metrics();

-- Chunk health per ChronoTable
SELECT * FROM lakets.chunk_health();

-- Top queries
SELECT * FROM lakets.query_stats(10);
```

## 9. Last Value Cache (Sub-10ms Latest State)

Enable a trigger-maintained cache for instant "what's the current value?" queries:

```sql
-- Enable LVC on your ChronoTable
SELECT lakets.enable_lvc(
    'system_metrics',
    key_columns   := ARRAY['host'],
    value_columns := ARRAY['cpu', 'memory']
);

-- Insert data (LVC auto-updates via trigger)
INSERT INTO system_metrics VALUES (now(), 'web-01', 'us-west-2', 'prod', 85.0, 7000, 500);

-- Query latest values (reads cache table — sub-10ms)
SELECT * FROM _lvc_system_metrics;
-- host   | cpu  | memory | last_updated
-- web-01 | 85.0 | 7000   | 2026-03-25 17:30:01

-- Cache stats
SELECT * FROM lakets.lvc_stats();
```

## 10. Cardinality Management

Monitor tag cardinality to prevent label explosion:

```sql
-- Distinct values per tag column
SELECT * FROM lakets.cardinality_stats('system_metrics');
-- column | distinct_values | total_rows | pct_of_rows
-- host   | 150             | 100000     | 0.150%
-- region | 5               | 100000     | 0.005%

-- Warn if combined cardinality exceeds threshold
SELECT * FROM lakets.cardinality_check('system_metrics', 10000);
-- status | combined_cardinality | max_allowed
-- OK     | 750                  | 10000
```

## 11. Alert Rules (Hot Data)

SQL-native alerting on recent data:

```sql
-- Threshold alert: find hosts with CPU > 90
SELECT * FROM lakets.alert_check(
    'high_cpu',
    $$SELECT host, max(cpu) as peak
      FROM system_metrics
      WHERE time > now() - interval '5 minutes'
      GROUP BY host HAVING max(cpu) > 90$$,
    'critical'
);

-- Deadman alert: hosts with no data for 5 minutes
SELECT * FROM lakets.alert_deadman(
    'stale_hosts', 'system_metrics', 'host', '5 minutes'
);
```

## 12. Bulk Ingest

Insert data in batches from edge devices or protocol adapters:

```sql
SELECT lakets.ingest_batch('system_metrics', '[
    {"time": "2026-03-25T17:00:00Z", "host": "edge-01", "region": "eu-1", "env": "prod", "cpu": 55.5, "memory": 2048, "disk_io": 100},
    {"time": "2026-03-25T17:00:01Z", "host": "edge-02", "region": "eu-1", "env": "prod", "cpu": 66.6, "memory": 4096, "disk_io": 200}
]'::JSONB);
```

## 13. Downsampling Pipeline (Metadata)

Register multi-resolution rollup pipelines (executed by Databricks Jobs):

```sql
SELECT lakets.create_downsample_pipeline(
    'metrics_rollups', 'system_metrics',
    ARRAY['1 minute', '1 hour', '1 day']::INTERVAL[],
    ARRAY['30 days', '1 year', '100 years']::INTERVAL[],
    ARRAY['avg(cpu)', 'max(memory)'],
    ARRAY['host', 'region']
);

-- Find best resolution for a given time range
SELECT * FROM lakets.query_auto_resolution('metrics_rollups', now() - '30 days');
```

## 14. Enable Lakehouse Sync (Optional)

Sync data to Delta Lake via CDC for analytics:
```sql
SELECT lakets.enable_sync('metrics');
```

See [lakehouse_sync_setup.md](lakehouse_sync_setup.md) for full setup instructions.

## Next Steps

- [API Reference](api_reference.md) - Complete function documentation
- [Lakehouse Sync Setup](lakehouse_sync_setup.md) - Delta Lake integration
- Deploy [Databricks Workflows](../databricks/bundles/databricks.yml) for automated partition management, compression, retention, and aggregate refresh
