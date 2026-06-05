---
title: Monitor your deployment
sidebar_label: Monitoring
sidebar_position: 4
description: Query operational metrics, chunk health, and top queries from inside Lakebase.
---

# Monitor a LakeTS deployment

LakeTS exposes operational state through SQL functions, so ChronoTable, RollUp, and query-workload visibility comes from inside Lakebase without an external metrics service. A Prometheus-compatible endpoint is also available for scraping from outside.

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

## Diagnose stalled tiering

When chunks past the policy age have not been flagged or dropped, `show_tiering_status` reports where the durability gate is held up:

```sql
SELECT * FROM lakets.show_tiering_status('metrics');
```

Read the result top-down:

- **`cdf_status`** — `NONE` means sync was never enabled (`lakets.enable_sync('metrics')` was never called); `SKIPPED` means the shadow table isn't streaming (often a missing `REPLICA IDENTITY FULL`); `STREAMING` means CDF is healthy.
- **`cdf_lag_bytes`** — how far CDF must still flush before the durability gate passes. While this is non-zero for pending chunks, the gate keeps deferring.
- **`caught_up`** — `TRUE` when the gate passes for every pending chunk. Once true, the next Tiering Job run flags those chunks `tiered`; retention then drops their partitions at `drop_after`.

Tiering is fail-closed: if CDF is `NONE`, `SKIPPED`, or still lagging, chunks are neither flagged nor dropped until the data is provably durable in Unity Catalog. See [Lakebase CDF Setup](../guides/lakebase-cdf-setup.md) to bring sync up.

## Top queries

```sql
SELECT * FROM lakets.query_stats(10);
```

Top N queries by total time, mean time, calls — useful for identifying which dashboard panels are hot enough to deserve a RollUp.

## Prometheus-compatible endpoint

The `monitoring/` module exposes a `/metrics` endpoint in Prometheus exposition format for scraping from outside Lakebase. See the [Monitoring reference](../reference/monitoring.md) for the full list of metrics functions.
