---
title: Lifecycle policies
sidebar_label: Lifecycle policies
sidebar_position: 4
description: Compression, tiering, and retention policy functions.
---

# Lifecycle policies

Functions that govern how chunks age out of the hot tier (Lakebase) and eventually out of the cold tier (Unity Catalog Managed Table). The actual data movement is performed by Databricks Jobs on a schedule; these functions register the policy + provide manual overrides.

## Compression & tiering

Tiering policies move data from the hot tier to the cold tier based on age. The Databricks Compression & Tiering job (daily at 2 AM) drives the actual movement.

### `add_compression_policy(p_table_name, p_compress_after, p_segment_by, p_order_by, p_schema_name)`

Registers a tiering policy for a ChronoTable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_compress_after` | INTERVAL | — | Tier chunks older than this |
| `p_segment_by` | TEXT | `NULL` | Column for segment optimization in the cold tier |
| `p_order_by` | TEXT | `NULL` | Column for Z-order optimization in the cold tier |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Tier data older than 30 days, segment by device_id
SELECT lakets.add_compression_policy(
    'sensor_data', '30 days',
    p_segment_by => 'device_id',
    p_order_by   => 'time'
);
```

### `compress_chunk(p_chunk_name)` / `decompress_chunk(p_chunk_name)`

Manually mark a specific chunk for tiering to the cold tier or for re-ingestion from cold back to Lakebase.

### `show_compression_policy(p_table_name, p_schema_name)`

Returns the compression/tiering policy for a ChronoTable.

**Returns**: TABLE — `policy_id`, `compress_after`, `segment_by`, `order_by`, `enabled`, `last_run_at`

### `remove_compression_policy(p_table_name, p_schema_name)`

Removes the compression/tiering policy.

### `_get_chunks_to_compress(p_table_name, p_schema_name)`

Internal. Returns chunks eligible for tiering (active chunks older than the `compress_after` threshold). Called by the Databricks Compression & Tiering workflow.

## Retention

Automatic lifecycle management — drop expired data from Lakebase and/or the Unity Catalog Managed Table.

### `add_retention_policy(p_table_name, p_drop_after, p_schema_name)`

Simple retention — drops Lakebase partitions older than `p_drop_after`.

**Returns**: `INT` — policy_id

```sql
-- Keep only 1 year of data in Lakebase
SELECT lakets.add_retention_policy('sensor_data', '365 days');
```

### `add_tiered_retention_policy(p_table_name, p_tier_after, p_drop_after, p_schema_name)`

Two-phase retention: tier to the UC Managed Table after `p_tier_after`, then delete from the UC Managed Table after `p_drop_after`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_tier_after` | INTERVAL | — | Move to the UC Managed Table after this age |
| `p_drop_after` | INTERVAL | — | Delete from the UC Managed Table after this age |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Hot 30 days → Cold up to 2 years → Delete
SELECT lakets.add_tiered_retention_policy(
    'sensor_data', '30 days', '730 days'
);
```

### `execute_retention(p_table_name, p_schema_name)`

Runs the retention policy — drops expired chunks. Called by the Databricks Retention job (daily at 3 AM).

**Returns**: `INT` — number of chunks dropped

### `show_retention_policy(p_table_name, p_schema_name)` / `remove_retention_policy(p_table_name, p_schema_name)`

View or remove the retention policy for a ChronoTable.
