---
title: Downsampling pipelines
sidebar_label: Downsampling pipelines
sidebar_position: 8
description: Multi-resolution rollup pipelines executed by Databricks Jobs, with automatic best-resolution routing.
---

# Downsampling pipelines

Multi-resolution data pipelines that automatically route queries to the finest available resolution based on the requested time range. The pipeline definition is stored as metadata on Lakebase; the actual aggregation runs on Databricks (Spark) and writes per-resolution outputs to a Unity Catalog Managed Table.

## `create_downsample_pipeline(p_name, p_source_table, p_intervals, p_retention, p_agg_expressions, p_group_by, p_delta_catalog, p_delta_schema, p_source_schema)`

Registers a multi-resolution pipeline. Metadata-only on Lakebase; execution happens on Databricks.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Pipeline name |
| `p_source_table` | TEXT | — | Source ChronoTable |
| `p_intervals` | INTERVAL[] | — | Resolutions, finest to coarsest |
| `p_retention` | INTERVAL[] | — | How long to keep each resolution |
| `p_agg_expressions` | TEXT[] | — | Aggregation expressions |
| `p_group_by` | TEXT[] | `NULL` | Group-by columns (tags) |
| `p_delta_catalog` | TEXT | `'main'` | UC catalog for output tables |
| `p_delta_schema` | TEXT | `'lakets_rollups'` | UC schema for output tables |
| `p_source_schema` | TEXT | `'public'` | Source table schema |

**Returns**: `INT` — pipeline_id

```sql
-- 3-tier resolution: 1m (30d), 1h (1y), 1d (10y)
SELECT lakets.create_downsample_pipeline(
    'sensor_multi_res',
    'sensor_data',
    ARRAY['1 minute', '1 hour', '1 day']::INTERVAL[],
    ARRAY['30 days', '365 days', '3650 days']::INTERVAL[],
    ARRAY['avg(temperature)', 'max(temperature)', 'min(temperature)'],
    ARRAY['device_id']
);
```

## `query_auto_resolution(p_name, p_start, p_end)`

Returns the best UC Managed Table for a given time range — picks the finest resolution whose retention covers the requested range.

**Returns**: TABLE — `resolution`, `delta_table`, `covers_range`

```sql
SELECT * FROM lakets.query_auto_resolution('sensor_multi_res', now() - interval '7 days');
-- 00:01:00 | main.lakets_rollups.sensor_multi_res_1_minute | true
```

## `show_downsample_pipelines()` / `drop_downsample_pipeline(p_name)`

List or remove downsample pipelines.
