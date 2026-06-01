---
title: Sync RollUps to Unity Catalog
sidebar_label: Sync to Unity Catalog
sidebar_position: 2
description: Expose RollUp Tables to Spark, BI, and ML by syncing them to a Unity Catalog Managed Table via Lakebase CDF.
---

# Sync RollUps to Unity Catalog

RollUp Tables live in Lakebase. To expose them to Spark jobs, BI dashboards, and ML pipelines, sync them to a Unity Catalog Managed Table via **Lakebase CDF**.

## Enable sync

```sql
SELECT lakets.enable_sync('metrics_hourly');
```

What this does:

1. Creates an unpartitioned shadow table `lakets_cdf._shadow_rollup_metrics_hourly` with `REPLICA IDENTITY FULL`.
2. Installs a mirror trigger that forwards every `INSERT` / `UPDATE` / `DELETE` from the RollUp Table to the shadow.
3. Lakebase CDF replicates the shadow to the Unity Catalog Managed Table `lb__shadow_rollup_metrics_hourly_history`.

:::note Why the shadow layer?
Lakebase CDF cannot replicate partitioned tables and fails on schemas that contain them. Synced tables are therefore isolated in the unpartitioned `lakets_cdf` schema. This layer is a workaround that can be removed once Lakebase lifts the partitioned-table limitation.
:::

## Disable sync

```sql
SELECT lakets.disable_sync('metrics_hourly');
```

Drops the shadow table and removes the mirror trigger. The UC destination table is **not** dropped.

## Notes

- RollUp sync assumes incremental refresh; the UC destination is an append-only change feed.
- `enable_sync` / `disable_sync` are idempotent — safe to call multiple times.
- To sync a ChronoTable (not a RollUp), use the same functions — see [Lakebase CDF setup](../guides/lakebase-cdf-setup.md).

## Reference

Full function signatures: [Lakebase CDF reference](../reference/lakebase-cdf.md).
