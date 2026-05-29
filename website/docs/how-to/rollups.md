---
title: Set up RollUps
sidebar_label: Set up RollUps
sidebar_position: 1
description: Create incremental rollups, build DAG dependencies, and refresh in topological order.
---

# Set up RollUps

A RollUp is a pre-computed, incrementally-maintained aggregation table. Dashboards query it directly instead of re-scanning raw data every refresh. Only the buckets that changed since the last refresh are recomputed.

## Create a RollUp

```sql
-- Create a hourly RollUp (incremental by default)
SELECT lakets.create_rollup(
    'metrics_hourly',
    $$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
             count(*) AS cnt,
             round(avg(cpu)::numeric, 2)    AS avg_cpu,
             round(avg(memory)::numeric, 2) AS avg_mem
      FROM metrics GROUP BY 1$$,
    '1 hour',
    'metrics'
);

-- Query pre-computed data — fast
SELECT * FROM _rollup_metrics_hourly ORDER BY bucket DESC LIMIT 10;
```

## Add a real-time view

Real-time views combine the pre-computed RollUp Table with a query for data newer than the watermark, so dashboards never see stale data.

```sql
SELECT lakets.create_rollup_view('metrics_hourly',
    $$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
             count(*) AS cnt,
             round(avg(cpu)::numeric, 2)    AS avg_cpu,
             round(avg(memory)::numeric, 2) AS avg_mem
      FROM metrics
      WHERE time > lakets._rollup_watermark('metrics_hourly')
      GROUP BY 1$$);

-- Always-fresh results
SELECT * FROM _rollup_rt_metrics_hourly ORDER BY bucket DESC LIMIT 10;
```

## Refresh incrementally

```sql
-- Only processes new/dirty buckets — not the entire dataset
SELECT lakets.refresh_rollup('metrics_hourly');
-- Returns TRUE (refreshed) or FALSE (skipped due to refresh_lag)
```

Enable invalidation tracking if historical data is ever corrected:

```sql
SELECT lakets.enable_rollup_invalidation('metrics_hourly');
```

## RollUp dependencies (DAG cascade)

Build hierarchical RollUps that refresh in the correct order — e.g. `metrics_daily` depends on `metrics_hourly`:

```sql
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

See [How RollUps Work](../guides/how-it-works/rollups.md) for the internals — watermark refresh, invalidation log, chunk-skip pruning, DAG cascade, and Unity Catalog export.
