---
title: Unity Catalog integration
sidebar_label: Unity Catalog
sidebar_position: 12
description: Register and tag exported Unity Catalog Managed Tables for governance, lineage, and discovery.
---

# Unity Catalog integration

Register and tag Unity Catalog Managed Table exports in Databricks Unity Catalog for governance, lineage, and discovery.

## `register_uc_table(p_rollup_name, p_uc_catalog, p_uc_schema)`

Records that a RollUp's UC export has been registered in Unity Catalog. Called by `uc_registration.py` after the REST API call.

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_rollup_name` | TEXT | RollUp name |
| `p_uc_catalog` | TEXT | UC catalog name |
| `p_uc_schema` | TEXT | UC schema name |

**Returns**: `INT` — registry row id

## `tag_uc_table(p_rollup_name, p_tags)`

Persists UC tag metadata. Merges system tags (`lakets.source`, `lakets.version`, `lakets.rollup_name`) with user-provided tags.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_rollup_name` | TEXT | — | RollUp name |
| `p_tags` | JSONB | `'{}'` | User-defined tags |

**Returns**: `JSONB` — merged tag set

```sql
SELECT lakets.tag_uc_table('hourly_sensors', '{"team": "iot", "env": "production"}');
-- Returns: {"team": "iot", "env": "production",
--          "lakets.source": "sensor_data",
--          "lakets.version": "0.1.2",
--          "lakets.rollup_name": "hourly_sensors"}
```

## `get_uc_registrations(p_rollup_name)`

Returns all UC-registered exports (optionally filtered by RollUp name).

**Returns**: TABLE — `rollup_name`, `uc_catalog`, `uc_schema`, `uc_table`, `full_uc_name`, `delta_table`, `registered_at`, `last_tagged_at`, `tags`

## `unregister_uc_table(p_rollup_name)`

Removes a UC-registration record from LakeTS metadata. Does NOT drop the actual UC table.

**Returns**: `BOOLEAN`
