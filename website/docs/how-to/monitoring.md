---
title: Monitor your deployment
sidebar_label: Monitoring
sidebar_position: 4
description: Query operational metrics, chunk health, and top queries from inside Lakebase.
---

# Monitor your LakeTS deployment

LakeTS ships three SQL views that give you operational visibility into ChronoTables, RollUps, and query workload — no external metrics service required.

## Operational metrics

```sql
SELECT * FROM lakets.lakets_metrics();
```

Returns chunk counts, row counts per ChronoTable, RollUp lag, compression backlog, and last refresh times.

## Chunk health

```sql
SELECT * FROM lakets.chunk_health();
```

Per-ChronoTable: count of `active` / `compressed` / `tiered` / `dropped` chunks, oldest chunk age, newest chunk age. Use this to confirm compression and retention are running.

## Top queries

```sql
SELECT * FROM lakets.query_stats(10);
```

Top N queries by total time, mean time, calls — useful for identifying which dashboard panels are hot enough to deserve a RollUp.

## Prometheus-compatible endpoint

The `monitoring/` module also exposes a `/metrics` endpoint in Prometheus exposition format if you want to scrape it from outside Lakebase. See the [Monitoring reference](../reference/monitoring.md) for the full list of metrics functions.
