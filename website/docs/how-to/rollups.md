---
title: Set up RollUps
sidebar_label: Set up RollUps
sidebar_position: 1
description: Create incremental rollups, build DAG dependencies, and refresh in topological order.
---

# Set up RollUps

A RollUp is a pre-computed, incrementally maintained aggregation table. Dashboards query it directly instead of re-scanning raw data on every refresh, and each refresh recomputes only the buckets that changed since the last one.

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

-- Query the pre-computed table directly
SELECT * FROM _rollup_metrics_hourly ORDER BY bucket DESC LIMIT 10;
```

## Add a real-time view

A real-time view unions the pre-computed RollUp table with a query over data newer than the watermark, so reads include rows that arrived since the last refresh.

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

RollUps can depend on other RollUps and refresh in dependency order. Here `metrics_daily` aggregates the hourly RollUp and declares it as a dependency:

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

See [How RollUps Work](../guides/how-it-works/rollups.md) for the internals: watermark refresh, the invalidation log, chunk-skip pruning, DAG cascade, and Lakebase CDF sync.
