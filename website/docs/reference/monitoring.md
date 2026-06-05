---
title: Monitoring
sidebar_label: Monitoring
sidebar_position: 11
description: Operational metrics, chunk health, and query stats — all queryable from inside Lakebase.
---

# Monitoring

Three SQL views give you operational visibility into ChronoTables, RollUps, and query workload. No external metrics service required — the same data can be scraped by `sql_exporter` for Prometheus.

## `lakets_metrics()`

Returns every LakeTS operational metric as key-value rows. Prometheus-compatible.

**Returns**: TABLE — `metric_name`, `metric_value`, `labels` (JSONB)

Metrics include total ChronoTables, total chunks by status, RollUp refresh lag, policy-execution stats, and more.

```sql
SELECT * FROM lakets.lakets_metrics();
-- lakets_chronotables_total         | 5    | {}
-- lakets_chunks_total               | 127  | {"status": "active"}
-- lakets_chunks_total               | 340  | {"status": "tiered"}
-- lakets_rollup_refresh_lag_seconds | 45.2 | {"rollup": "hourly_sensors"}
```

Chunk counts are emitted as a single `lakets_chunks_total` metric labelled by `status` (one row per status), and RollUp lag is emitted as two metrics: `lakets_rollup_watermark_lag_seconds` and `lakets_rollup_refresh_lag_seconds`.

### Tiering metrics

`lakets_metrics()` emits three per-table tiering metrics (labelled by `table`):

| Metric | Meaning |
|--------|---------|
| `lakets_tiering_pending_chunks{table}` | Aged-out chunks not yet validated durable in UC |
| `lakets_tiering_tiered_chunks_total{table}` | Chunks validated durable in UC and flagged `tiered` (still resident in Lakebase) |
| `lakets_tiering_caught_up{table}` | `1` when the durability gate currently passes for all pending chunks, else `0` |

## `chunk_health()`

Per-ChronoTable chunk-health breakdown.

**Returns**: TABLE — `chronotable`, `total_chunks`, `active_chunks`, `tiered_chunks`, `dropped_chunks`, `oldest_active`, `newest_active`

## `show_tiering_status(p_table_name, p_schema_name)`

Per-ChronoTable view of tiering progress and CDF durability — the function to reach for when chunks aren't being flagged or dropped. Both parameters are optional; with no arguments it reports every table that has a tiering policy.

**Returns**: TABLE

| Column | Type | Description |
|--------|------|-------------|
| `schema_name` | TEXT | Schema of the ChronoTable |
| `table_name` | TEXT | ChronoTable name |
| `after` | TEXT | Tiering threshold (e.g. `7 days`) |
| `active_chunks` | INT | Resident, not yet validated durable in UC |
| `tiered_chunks` | INT | Validated durable in UC, still resident in Lakebase (ready to drop) |
| `pending_chunks` | INT | Aged past `tier_after`, awaiting validation |
| `reclaimable_bytes` | BIGINT | Lakebase storage held by `tiered` chunks (droppable at `drop_after`) |
| `reclaimed_bytes` | BIGINT | Lakebase storage already freed by `dropped` chunks |
| `cdf_status` | TEXT | `STREAMING`, `SKIPPED`, or `NONE` |
| `cdf_lag_bytes` | BIGINT | How far CDF must still flush before the gate passes |
| `caught_up` | BOOLEAN | `TRUE` when the gate passes for all pending chunks |
| `last_run_at` | TIMESTAMPTZ | Last time the tiering job ran for this table |

Read `cdf_status` as:

- **`NONE`** — sync was never enabled for this table (`lakets.enable_sync()` not called).
- **`SKIPPED`** — the shadow exists but isn't streaming (e.g. missing `REPLICA IDENTITY FULL`).
- **`STREAMING`** — CDF is healthy; validation and gated drops can proceed once `caught_up` is `TRUE`.

## `query_stats(p_limit)`

Top queries by total execution time. Wraps `pg_stat_statements`; returns empty if the extension is unavailable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_limit` | INT | `20` | Number of top queries to return |

**Returns**: TABLE — `query`, `calls`, `total_time_ms`, `mean_time_ms`, `rows_returned`
