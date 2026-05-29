---
title: Lakebase CDF
sidebar_label: Lakebase CDF
sidebar_position: 5
description: Shadow-sync functions that route partitioned writes through an unpartitioned shadow table for Lakebase CDF replication.
---

# Lakebase CDF

Lakebase CDF can't replicate partitioned tables directly. LakeTS works around this by creating an unpartitioned **shadow table** that mirrors every write — Lakebase CDF then replicates the shadow to a Unity Catalog Managed Table.

## `enable_sync(p_table_name, p_schema_name)`

Creates the shadow table `_shadow_{table}` and installs a trigger that forwards every `INSERT` / `UPDATE` / `DELETE`. Sets `REPLICA IDENTITY FULL` on the shadow for complete CDC capture.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable to sync |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
-- Enable Lakebase CDF on a partitioned ChronoTable
SELECT lakets.enable_sync('sensor_data');
-- Creates: _shadow_sensor_data (unpartitioned, CDC-enabled)
```

## `disable_sync(p_table_name, p_schema_name)`

Drops the shadow table and removes the trigger.

**Returns**: `VOID`

## `_sync_trigger_fn()`

Internal trigger function. Dynamically routes writes from any partition to the correct shadow table using `TG_TABLE_SCHEMA` and `TG_TABLE_NAME`.
