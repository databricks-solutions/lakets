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

Returns chunk counts, row counts per ChronoTable, RollUp lag, tiering backlog (`lakets_tiering_pending_chunks`, `lakets_tiering_tiered_chunks_total`, `lakets_tiering_caught_up`), and last refresh times.

## Chunk health

```sql
SELECT * FROM lakets.chunk_health();
```

Per-ChronoTable: count of `active` / `tiered` / `dropped` chunks, oldest chunk age, newest chunk age. Use this to confirm tiering and retention are running.

## Why isn't my data tiering?

When chunks past the policy age aren't being evicted, ask `show_tiering_status`:

```sql
SELECT * FROM lakets.show_tiering_status('metrics');
```

Read the result top-down:

- **`cdf_status`** — `NONE` means sync was never enabled (`lakets.enable_sync('metrics')` was never called); `SKIPPED` means the shadow table isn't streaming (often a missing `REPLICA IDENTITY FULL`); `STREAMING` means CDF is healthy.
- **`cdf_lag_bytes`** — how far CDF must still flush before the durability gate passes. While this is non-zero for pending chunks, the gate keeps deferring.
- **`caught_up`** — `TRUE` when the gate passes for every pending chunk. Once true, the next Tiering Job run will drop those partitions.

Tiering is fail-closed: if CDF is `NONE`, `SKIPPED`, or still lagging, partitions are kept until the data is provably durable in Unity Catalog. See [Lakebase CDF Setup](../guides/lakebase-cdf-setup.md) to bring sync up.

## Top queries

```sql
SELECT * FROM lakets.query_stats(10);
```

Top N queries by total time, mean time, calls — useful for identifying which dashboard panels are hot enough to deserve a RollUp.

## Prometheus-compatible endpoint

The `monitoring/` module also exposes a `/metrics` endpoint in Prometheus exposition format if you want to scrape it from outside Lakebase. See the [Monitoring reference](../reference/monitoring.md) for the full list of metrics functions.
