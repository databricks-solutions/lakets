---
title: Lifecycle policies
sidebar_label: Lifecycle policies
sidebar_position: 4
description: Tiering and retention policy functions.
---

# Lifecycle policies

Functions that govern how chunks age out of the hot tier (Lakebase) and eventually out of the cold tier (Unity Catalog Managed Table). The actual data movement is performed by Databricks Jobs on a schedule; these functions register the policy + provide manual overrides.

## Tiering

Tiering evicts data from the hot tier (Lakebase) once Lakebase CDF has durably flushed it to the cold tier (Unity Catalog Managed Table), based on age. The Databricks Tiering job (daily at 2 AM) drives the actual eviction.

CDF must be enabled and the table CDF-synced via `lakets.enable_sync()` before anything is evicted — see [Lakebase CDF Setup](../guides/lakebase-cdf-setup.md).

### `add_tiering_policy(p_table_name, p_after, p_schema_name)`

Registers a tiering policy for a ChronoTable. Also installs the triggers that stamp each chunk's `last_write_lsn` (used by the durability gate). Creates the policy even if the table isn't CDF-synced yet (with a NOTICE), but nothing is evicted until sync and CDF are live.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_after` | INTERVAL | — | Evict chunks older than this |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Evict chunks older than 7 days
SELECT lakets.add_tiering_policy('metrics', '7 days');
```

### `tier_chunk(p_chunk_name)`

Drops the chunk's Lakebase partition and marks it `tiered` — but **only if the durability gate passes** (the chunk's CDF shadow is `STREAMING` and CDF's `committed_lsn` for that shadow is `>=` the chunk's own `last_write_lsn`). The gate is fail-closed.

**Returns**: `BOOLEAN` — `TRUE` if the partition was dropped, `FALSE` if deferred (retried on the next job run).

### `untier_chunk(p_chunk_name)`

Restores a `tiered` chunk's metadata to `active` — e.g. before re-ingesting it from the Unity Catalog Managed Table.

**Returns**: `VOID`

### `show_tiering_policy(p_table_name, p_schema_name)`

Returns the tiering policy for a ChronoTable.

**Returns**: TABLE — `policy_id` (INT), `after` (TEXT), `enabled` (BOOLEAN), `last_run_at` (TIMESTAMPTZ)

### `remove_tiering_policy(p_table_name, p_schema_name)`

Removes the tiering policy.

### `_get_chunks_to_tier(p_table_name, p_schema_name)`

Internal. Returns chunks eligible for tiering (active chunks older than the `after` threshold). Called by the Databricks Tiering workflow, which then calls `tier_chunk()` per candidate.

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

`show_retention_policy` **returns**: TABLE — `policy_id`, `policy_type` (`'retention'` or `'tiered_retention'`), `drop_after`, `tier_after`, `enabled`, `last_run_at`.

`remove_retention_policy` **returns**: `VOID`.
