---
title: Function reference — Overview
sidebar_label: Overview
sidebar_position: 0
description: Topic-by-topic index for every LakeTS function, aggregate, trigger, and metadata table.
---

# Function reference

Every LakeTS function, custom aggregate, trigger, and metadata table — grouped by what it does. All objects live in the `lakets` schema.

## By topic

### Core data model
- **[ChronoTables](./chronotables.md)** — create, manage, list, drop time-partitioned tables
- **[Multi-metric tables](./multi-metric-tables.md)** — InfluxDB-style tag + field model + cardinality controls
- **[Metadata tables](./metadata-tables.md)** — the `lakets` schema's state-management tables

### Query
- **[Time-series functions](./time-series-functions.md)** — `time_bucket`, `first`, `last`, `locf`, `interpolate`, `delta`, `rate`, `gap-fill`, `histogram`

### Aggregation
- **[RollUps](./rollups.md)** — incremental aggregation engine + scale optimizations

### Lifecycle
- **[Lifecycle policies](./lifecycle.md)** — tiering, retention
- **[Lakebase CDF](./lakebase-cdf.md)** — shadow-table sync to Unity Catalog (ChronoTables and RollUps)

### Operations
- **[Last Value Cache](./last-value-cache.md)** — sub-10 ms current-state reads
- **[Alerts](./alerts.md)** — SQL-native threshold and deadman alerts
- **[Bulk ingest](./bulk-ingest.md)** — JSONB batch + Prometheus-format ingest
- **[Monitoring](./monitoring.md)** — operational metrics and chunk health
- **[Workflow jobs](./workflow-jobs.md)** — the Databricks Jobs that drive the operational lifecycle

## At a glance

| Module group | Functions | Aggregates | Triggers |
|---|---|---|---|
| ChronoTables (incl. multi-metric) | 9 | — | — |
| Time-series analytics | 7 | 2 | — |
| RollUps (engine + optimization) | 26 | — | 4 |
| Lifecycle (tiering + retention) | 11 | — | — |
| Lakebase CDF | 3 | — | 1 |
| Last Value Cache | 5 | — | 1 |
| Alerts | 2 | — | — |
| Bulk ingest | 2 | — | — |
| Monitoring | 3 | — | — |
| Schema utilities | 1 | — | — |
| **Total** | **69** | **2** | **6** |

All objects in the `lakets` schema. PostgreSQL 17+ required (Lakebase default). No custom extensions.
