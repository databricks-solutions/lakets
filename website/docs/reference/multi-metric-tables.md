---
title: Multi-metric tables
sidebar_label: Multi-metric tables
sidebar_position: 6
description: Functions for InfluxDB-style tag + field ChronoTables and tag-cardinality controls.
---

# Multi-metric tables

InfluxDB-style tag + field model for multi-metric time-series data. A multi-metric ChronoTable indexes its tag columns automatically and exposes cardinality controls so you can catch label explosion early.

## `create_metric_table(p_table_name, p_tag_columns, p_field_columns, p_chunk_interval, p_schema_name)`

Creates a ChronoTable optimized for multi-metric data with automatic indexing on tag columns.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Table name |
| `p_tag_columns` | TEXT[] | — | Tag columns (indexed `TEXT`, low cardinality) |
| `p_field_columns` | TEXT[] | — | Field columns (`DOUBLE PRECISION`, high cardinality) |
| `p_chunk_interval` | INTERVAL | `'1 day'` | Partition interval |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — chronotable_id

```sql
SELECT lakets.create_metric_table(
    'system_metrics',
    ARRAY['host', 'datacenter', 'service'],   -- tags
    ARRAY['cpu_pct', 'mem_pct', 'disk_io'],   -- fields
    '1 day'
);
```

## `cardinality_stats(p_table_name, p_schema_name)`

Distinct value counts per tag column — essential for catching series explosion.

**Returns**: TABLE — `column_name`, `distinct_values`, `total_rows`, `pct_of_rows`

## `cardinality_check(p_table_name, p_max_series, p_schema_name)`

Warns if combined cardinality across all tag columns exceeds a threshold.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Metric table name |
| `p_max_series` | BIGINT | `100000` | Maximum allowed series count |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: TABLE — `status` (`'OK'` or `'WARNING'`), `combined_cardinality`, `max_allowed`, `tag_columns`

```sql
SELECT * FROM lakets.cardinality_check('system_metrics');
-- OK | 2500 | 100000 | host,datacenter,service
```
