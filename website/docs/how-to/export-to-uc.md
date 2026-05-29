---
title: Export RollUps to Unity Catalog
sidebar_label: Export to Unity Catalog
sidebar_position: 2
description: Make RollUp Tables available to Spark, ML pipelines, and BI tools via a Unity Catalog Managed Table.
---

# Export RollUps to a Unity Catalog Managed Table

RollUp Tables live in Lakebase. To make them visible to Spark jobs, BI tools, and ML pipelines, export them to a Unity Catalog Managed Table.

## Enable export

```sql
SELECT lakets.enable_rollup_export(
    'metrics_hourly',
    'main.lakets_rollups.metrics_hourly',  -- destination UC table path
    'incremental'                           -- 'full' or 'incremental'
);
```

Export modes:

| Mode | Behaviour |
|------|-----------|
| `full` | `OVERWRITE` the UC Managed Table on every run |
| `incremental` | `APPEND` only rows newer than `last_exported_at` |

## Inspect export status

```sql
SELECT * FROM lakets.show_rollup_exports();
```

## Disable export

```sql
SELECT lakets.disable_rollup_export('metrics_hourly');
```

## What runs the export

The actual data movement is performed by the `rollup_export.py` Databricks Job, which reads every RollUp where `export_enabled = TRUE` and writes to the configured UC table path. Schedule it on whatever cadence your downstream consumers need (default in the bundle: daily at 4 AM).

See [How RollUps Work — Unity Catalog export](../guides/how-it-works/rollups.md#unity-catalog-export--rollup-tables-visible-to-spark--bi--ml) for the internals.
