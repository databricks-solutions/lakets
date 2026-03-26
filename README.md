# LakeTS - Time Series Toolkit for Databricks Lakebase

LakeTS brings TimescaleDB-equivalent time series capabilities to Databricks Lakebase using a pure SQL + Delta Lake hybrid architecture. No custom extensions required.

## Features

| Feature | Description |
|---------|-------------|
| **ChronoTables** | Automatic time-based partitioning with `create_chronotable()` |
| **Multi-Metric Tables** | InfluxDB-style tag + field model with `create_metric_table()` |
| **Time Series Functions** | `time_bucket`, `first`, `last`, `locf`, `interpolate`, `delta`, `rate`, `histogram` |
| **Gap-filling** | `time_bucket_gapfill` + LEFT JOIN for continuous time series |
| **RollUp Engine** | Incremental aggregates with per-bucket refresh, invalidation tracking, and cold-tier re-aggregation |
| **Compression & Tiering** | Policy-based tiering from Lakebase to Delta Lake |
| **Retention** | Automated data lifecycle management across both tiers |
| **Lakehouse Sync** | CDC-based replication to Delta via shadow table pattern |
| **Last Value Cache** | Sub-10ms latest-state queries via `enable_lvc()` |
| **Cardinality Management** | Tag cardinality explorer + threshold checks |
| **Alert Rules** | SQL-native `alert_check()` + `alert_deadman()` on hot data |
| **Bulk Ingest** | `ingest_batch()` for JSONB arrays + `ingest_prometheus()` |
| **Downsampling Registry** | Multi-resolution pipeline metadata + `query_auto_resolution()` |
| **Monitoring** | Prometheus-compatible metrics endpoint |
| **Benchmarks** | TSBS-adapted suite with TimescaleDB comparison |

## Quick Start

```sql
-- 1. Install (run against Lakebase)
\ir sql/99_install.sql

-- 2. Create a ChronoTable (single-metric)
CREATE TABLE metrics (time TIMESTAMPTZ NOT NULL, device TEXT, cpu FLOAT8);
SELECT lakets.create_chronotable('metrics', 'time', '1 day');

-- 2b. Or create a Multi-Metric ChronoTable (InfluxDB-style)
SELECT lakets.create_metric_table('system_metrics',
    ARRAY['host','region'], ARRAY['cpu','memory','disk_io'], '1 day');

-- 3. Query with time series functions
SELECT lakets.time_bucket('1 hour'::interval, time) AS hour,
       avg(cpu), lakets.first(cpu, time), lakets.last(cpu, time)
FROM metrics GROUP BY 1 ORDER BY 1;

-- 4. Enable Last Value Cache (sub-10ms latest state)
SELECT lakets.enable_lvc('system_metrics', ARRAY['host'], ARRAY['cpu','memory']);

-- 5. Set up lifecycle policies
SELECT lakets.add_compression_policy('metrics', '7 days');
SELECT lakets.add_retention_policy('metrics', '30 days');
```

## Architecture

```
Application (Grafana / Telegraf / Custom)
    |
LakeTS Toolkit (PL/pgSQL functions)
    |
+-------------------+    +---------------------+
| HOT: Lakebase     |    | COLD: Delta Lake    |
| - Partitioned     |    | - Columnar Parquet  |
| - Sub-10ms reads  |    | - Photon analytics  |
| - Real-time write | -> | - Unity Catalog     |
+-------------------+    +---------------------+
   (Lakehouse Sync CDC)
```

## Project Structure

```
sql/               -- SQL functions (install on Lakebase)
tests/             -- SQL test suites
databricks/        -- Workflow jobs + Asset Bundle
benchmarks/        -- TSBS-adapted benchmark suite
docs/              -- Documentation
```

## Documentation

- [Getting Started](docs/getting_started.md) - Install, create ChronoTables, query
- [API Reference](docs/api_reference.md) - All 61+ functions documented
- [Migration from TimescaleDB](docs/migration_from_timescaledb.md) - Function mapping + migration steps
- [Lakehouse Sync Setup](docs/lakehouse_sync_setup.md) - Delta Lake integration

## Benchmark Results (50K rows, CU_1)

| Benchmark | LakeTS | TimescaleDB Baseline |
|-----------|--------|---------------------|
| Ingest | 548K rows/sec | ~500K rows/sec |
| Gap-Fill | 11ms | ~10ms |
| RollUp Incremental Refresh | <10ms (incremental) | ~200ms (full rebuild) |

## Requirements

- Databricks workspace with Lakebase
- PostgreSQL 16+ (Lakebase default)
- For workflows: Databricks cluster with `psycopg2` + SDK

