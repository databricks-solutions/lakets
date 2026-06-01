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
-- lakets_hypertables_total          | 5    | {}
-- lakets_chunks_total               | 127  | {"status": "active"}
-- lakets_chunks_total               | 340  | {"status": "tiered"}
-- lakets_rollup_refresh_lag_seconds | 45.2 | {"rollup": "hourly_sensors"}
```

Chunk counts are emitted as a single `lakets_chunks_total` metric labelled by `status` (one row per status), and RollUp lag is emitted as two metrics: `lakets_rollup_watermark_lag_seconds` and `lakets_rollup_refresh_lag_seconds`.

## `chunk_health()`

Per-ChronoTable chunk-health breakdown.

**Returns**: TABLE — `hypertable`, `total_chunks`, `active_chunks`, `compressed_chunks`, `tiered_chunks`, `dropped_chunks`, `oldest_active`, `newest_active`

## `query_stats(p_limit)`

Top queries by total execution time. Wraps `pg_stat_statements`; returns empty if the extension is unavailable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_limit` | INT | `20` | Number of top queries to return |

**Returns**: TABLE — `query`, `calls`, `total_time_ms`, `mean_time_ms`, `rows_returned`
