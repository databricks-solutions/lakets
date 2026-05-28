---
slug: /
title: LakeTS
description: Time Series Toolkit for Databricks Lakebase
---

# LakeTS

**Time series toolkit for Databricks Lakebase** — pure SQL (PL/pgSQL) functions with a hot tier (Lakebase) + cold tier (Delta Lake) hybrid architecture. No custom extensions required.

## Quick start

Install the single-file distribution on a Lakebase instance:

```bash
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql.sha256
sha256sum -c lakets.sql.sha256
psql -h <host> -U <user> -d <database> -f lakets.sql
```

Then create your first ChronoTable:

```sql
CREATE TABLE metrics (time TIMESTAMPTZ NOT NULL, device TEXT, cpu FLOAT8);
SELECT lakets.create_chronotable('metrics', 'time', '1 day');
```

## What's included

- **ChronoTables** — automatic time-based partitioning
- **Multi-Metric Tables** — InfluxDB-style tag + field model
- **Time series functions** — `time_bucket`, `first`, `last`, `locf`, `interpolate`, `delta`, `rate`, `histogram`
- **Gap-filling** — `time_bucket_gapfill` for continuous time series
- **RollUp engine** — incremental aggregates with DAG orchestration and Delta export
- **Compression & Tiering** — Lakebase → Delta Lake lifecycle
- **Last Value Cache** — sub-10ms latest-state queries
- **Lakehouse Sync** — CDC-based Delta replication
- **Unity Catalog Integration** — register and tag Delta exports
- **Bulk Ingest** — JSONB batch + Prometheus formats

## Docs roadmap

This site is the skeleton for the LakeTS documentation. Existing Markdown guides in [`docs/`](https://github.com/databricks-solutions/lakets/tree/main/docs) on the main repository will be migrated here over upcoming releases:

- Getting started
- How it works (architecture)
- API reference
- Lakehouse Sync setup
- Function reference (70+ entries)

Until then, the canonical docs live in the [GitHub repository](https://github.com/databricks-solutions/lakets).
