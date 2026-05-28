---
title: Introduction
sidebar_label: Introduction
sidebar_position: 0
description: LakeTS is a pure-SQL time series toolkit for Databricks Lakebase, with a hot Lakebase + cold Delta tier hybrid architecture.
---

# LakeTS

**Time series toolkit for Databricks Lakebase.** Pure SQL (PL/pgSQL) — no custom PostgreSQL extensions required.

LakeTS turns Lakebase into a full time series database with automatic partitioning, time bucketing, gap-filling, incremental rollups, and tiered storage. The hot tier is Lakebase (sub-10ms queries on the latest data); the cold tier is Delta Lake (cheap retention + Photon analytics). Lakehouse Sync streams between them via CDC.

## Quick start

Install the single-file distribution on a Lakebase instance:

```bash
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql.sha256
sha256sum -c lakets.sql.sha256
psql -h <host> -U <user> -d <database> -f lakets.sql
```

Create your first ChronoTable:

```sql
CREATE TABLE metrics (time TIMESTAMPTZ NOT NULL, device TEXT, cpu FLOAT8);
SELECT lakets.create_chronotable('metrics', 'time', '1 day');

-- Query with time series functions
SELECT lakets.time_bucket('1 hour'::interval, time) AS hour,
       avg(cpu), lakets.first(cpu, time), lakets.last(cpu, time)
FROM metrics GROUP BY 1 ORDER BY 1;
```

Continue with the [Getting Started guide](./guides/getting-started.md) for the full walk-through, or jump to [How It Works](./guides/how-it-works.md) for the architecture.

## What's included

- **ChronoTables** — automatic time-based partitioning
- **Multi-Metric Tables** — InfluxDB-style tag + field model
- **Time series functions** — `time_bucket`, `first`, `last`, `locf`, `interpolate`, `delta`, `rate`, `histogram`
- **Gap-filling** — `time_bucket_gapfill` for continuous time series
- **RollUp engine** — incremental aggregates with DAG orchestration and Delta export
- **Compression & Tiering** — Lakebase → Delta Lake lifecycle policies
- **Retention** — automated lifecycle management across both tiers
- **Lakehouse Sync** — CDC-based Delta replication via shadow tables
- **Last Value Cache** — sub-10ms latest-state queries
- **Unity Catalog integration** — register and tag Delta exports
- **Bulk Ingest** — JSONB batch + Prometheus formats
- **Alert rules** — SQL-native threshold and deadman alerts
- **Monitoring** — Prometheus-compatible metrics endpoint

## Where to next

| If you want to… | Read |
|---|---|
| Get hands-on quickly | [Getting Started](./guides/getting-started.md) |
| Understand the architecture | [How It Works](./guides/how-it-works.md) |
| Set up Delta replication | [Lakehouse Sync Setup](./guides/lakehouse-sync-setup.md) |
| Look up a function signature | [API Reference](./reference/api-reference.md) |
| Browse the full catalog | [Function Reference](./reference/function-reference.md) |
