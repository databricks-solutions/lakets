---
title: Lifecycle policies
sidebar_label: Lifecycle policies
sidebar_position: 4
description: Tiering and retention policy functions.
---

# Lifecycle policies

Functions that govern how chunks age out of the hot tier (Lakebase). The actual work is performed by Databricks Jobs on a schedule; these functions register the policy and provide manual overrides. LakeTS only ever removes data from Lakebase — the Unity Catalog Managed Table copy is retained.

## Tiering

Tiering **validates** that a chunk is durable in the Unity Catalog Managed Table (via Lakebase CDF) and flags it `tiered`. The chunk's data stays in Lakebase and remains queryable; the partition is physically removed later by retention at `drop_after`. The Databricks Tiering job drives the validation.

CDF must be enabled and the table CDF-synced via `lakets.enable_sync()` before any chunk is flagged — see [Lakebase CDF Setup](../guides/lakebase-cdf-setup.md).

### `add_tiering_policy(p_table_name, p_after, p_schema_name)`

Registers a tiering policy for a ChronoTable. Also installs the triggers that stamp each chunk's `last_write_lsn` (used by the durability gate). Creates the policy even if the table isn't CDF-synced yet (with a NOTICE), but no chunk is flagged until sync and CDF are live.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_after` | INTERVAL | — | Validate + flag chunks older than this |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Flag chunks older than 7 days as durable-in-UC
SELECT lakets.add_tiering_policy('metrics', '7 days');
```

### `tier_chunk(p_chunk_name)`

Marks the chunk `tiered` — but **only if the durability gate passes** (the chunk's CDF shadow is `STREAMING` and CDF's `committed_lsn` for that shadow is `>=` the chunk's own `last_write_lsn`). The gate is fail-closed. The chunk's partition is **not** dropped; the data stays in Lakebase until retention removes it at `drop_after`.

**Returns**: `BOOLEAN` — `TRUE` if the chunk was flagged, `FALSE` if deferred (retried on the next job run).

### `untier_chunk(p_chunk_name)`

Restores a `tiered` chunk's metadata to `active` — e.g. before re-ingesting it from the Unity Catalog Managed Table.

**Returns**: `VOID`

### `show_tiering_policy(p_table_name, p_schema_name)`

Returns the tiering policy for a ChronoTable.

**Returns**: TABLE — `policy_id` (INT), `after` (TEXT), `enabled` (BOOLEAN), `last_run_at` (TIMESTAMPTZ)

### `remove_tiering_policy(p_table_name, p_schema_name)`

Removes the tiering policy.

### `_get_chunks_to_tier(p_table_name, p_schema_name)`

Internal. Returns candidate chunks to validate (active chunks older than the `after` threshold). Called by the Databricks Tiering workflow, which then calls `tier_chunk()` per candidate.

## Retention

Drops expired chunk partitions from **Lakebase**. Retention is the only step that removes data from Lakebase; it never deletes from the Unity Catalog Managed Table.

### `add_retention_policy(p_table_name, p_drop_after, p_schema_name)`

Simple retention — drops Lakebase partitions older than `p_drop_after`.

**Returns**: `INT` — policy_id

```sql
-- Keep only 1 year of data in Lakebase
SELECT lakets.add_retention_policy('sensor_data', '365 days');
```

### `add_tiered_retention_policy(p_table_name, p_tier_after, p_drop_after, p_schema_name)`

Declares both horizons for the Lakebase copy: validate + flag the chunk as durable in UC after `p_tier_after` (tiering job), then drop the Lakebase partition after `p_drop_after` (retention job). Validates that `p_tier_after < p_drop_after`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_tier_after` | INTERVAL | — | Validate + flag the chunk durable-in-UC after this age |
| `p_drop_after` | INTERVAL | — | Drop the Lakebase partition after this age |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Hot+flagged in Lakebase to 30 days → Lakebase partition dropped at 2 years
SELECT lakets.add_tiered_retention_policy(
    'sensor_data', '30 days', '730 days'
);
```

### `execute_retention(p_table_name, p_schema_name, p_force)`

Drops the Lakebase partition of each chunk older than `drop_after`. The drop is **gated** whenever the chunk's data is expected to persist in UC — a CDF-synced table **or** a `tiered_retention` policy — so a chunk is dropped only if provably durable (`committed_lsn ≥ last_write_lsn`), otherwise deferred. Only plain `retention` on an un-synced table drops outright. `p_force => TRUE` (default `FALSE`) bypasses the durability check. Called by the Databricks Retention job. Never deletes from the Unity Catalog Managed Table.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_schema_name` | TEXT | `'public'` | Schema |
| `p_force` | BOOLEAN | `FALSE` | Drop even if the chunk isn't validated durable in UC |

**Returns**: `INT` — number of partitions dropped

### `show_retention_policy(p_table_name, p_schema_name)` / `remove_retention_policy(p_table_name, p_schema_name)`

View or remove the retention policy for a ChronoTable.

`show_retention_policy` **returns**: TABLE — `policy_id`, `policy_type` (`'retention'` or `'tiered_retention'`), `drop_after`, `tier_after`, `enabled`, `last_run_at`.

`remove_retention_policy` **returns**: `VOID`.
