---
title: Downsampling pipelines
sidebar_label: Downsampling pipelines
sidebar_position: 9
description: Register multi-resolution rollup pipelines that are executed by Databricks Jobs.
---

# Downsampling pipelines

A downsampling pipeline registers a multi-resolution rollup plan as metadata on Lakebase. The actual aggregation runs on Databricks Jobs (via Spark), which then write the per-resolution outputs to a Unity Catalog Managed Table.

Use this when you need very long horizons (months to years) where keeping the data in Lakebase isn't worth the cost — store fine-grained recent data hot, push coarser aggregates to cold storage at scale.

## Register a pipeline

```sql
SELECT lakets.create_downsample_pipeline(
    'metrics_rollups',          -- pipeline name
    'system_metrics',           -- source ChronoTable
    ARRAY['1 minute', '1 hour', '1 day']::INTERVAL[],   -- resolutions
    ARRAY['30 days', '1 year', '100 years']::INTERVAL[], -- retention per resolution
    ARRAY['avg(cpu)', 'max(memory)'],                    -- aggregation expressions
    ARRAY['host', 'region']                              -- group-by columns
);
```

This stores the pipeline definition in `_downsample_pipelines` (registry only — no data movement yet). The Databricks Downsample Job reads the registry, runs the Spark aggregations, and writes per-resolution outputs.

## Query auto-resolution

Given a time range, ask the pipeline which resolution is the best fit:

```sql
SELECT * FROM lakets.query_auto_resolution('metrics_rollups', now() - '30 days');
```

Returns the finest resolution whose retention covers the requested range. Use this in dashboard backends to point each query at the smallest table that has the needed history.

## When to use a pipeline vs a RollUp

| Need | Use |
|---|---|
| Sub-hour latency, < a few months of history | [RollUps](./rollups.md) |
| Multi-year history at coarse granularity | Downsampling pipeline |
| Both | Both — RollUps for hot, pipelines for cold |
