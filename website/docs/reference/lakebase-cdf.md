---
title: Lakebase CDF
sidebar_label: Lakebase CDF
sidebar_position: 5
description: Shadow-sync functions that route partitioned writes through an unpartitioned shadow table for Lakebase CDF replication to Unity Catalog.
---

# Lakebase CDF

Lakebase CDF can't replicate partitioned tables directly. LakeTS works around this by creating an unpartitioned **shadow table** in the `lakets_cdf` schema that mirrors every write — Lakebase CDF then replicates the shadow to a Unity Catalog Managed Table.

`enable_sync` and `disable_sync` work for **both ChronoTables and RollUps**. The shadow lives in `lakets_cdf`; the UC destination table is named `lb_<shadow>_history`.

## `enable_sync(p_table_name, p_schema_name)`

Creates the shadow table `lakets_cdf._shadow_{table}` and installs a trigger that forwards every `INSERT` / `UPDATE` / `DELETE`. Sets `REPLICA IDENTITY FULL` on the shadow for complete CDC capture.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable or RollUp to sync |
| `p_schema_name` | TEXT | `'public'` | Schema containing the source table |

**Returns**: `VOID`

```sql
-- Enable Lakebase CDF on a partitioned ChronoTable
SELECT lakets.enable_sync('sensor_data');
-- Creates: lakets_cdf._shadow_sensor_data  →  UC table lb__shadow_sensor_data_history

-- Enable Lakebase CDF on a RollUp
SELECT lakets.enable_sync('metrics_hourly');
-- Creates: lakets_cdf._shadow_rollup_metrics_hourly  →  UC table lb__shadow_rollup_metrics_hourly_history
```

## `disable_sync(p_table_name, p_schema_name)`

Drops the shadow table and removes the trigger. The UC destination table is **not** dropped.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Table name passed to `enable_sync` |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

Both `enable_sync` and `disable_sync` are idempotent.

## `_sync_trigger_fn()`

Internal trigger function. Dynamically routes writes from any partition or RollUp table to the correct shadow table in `lakets_cdf` using `TG_TABLE_SCHEMA` and `TG_TABLE_NAME`.

## Why `lakets_cdf` exists

Lakebase CDF fails on schemas that contain partitioned tables. Synced (unpartitioned) shadows are therefore isolated in the dedicated `lakets_cdf` schema. This isolation layer can be removed once Lakebase lifts the partitioned-table limitation.

## How-to guide

See [Sync RollUps to Unity Catalog](../how-to/export-to-uc.md) for a step-by-step walkthrough.
