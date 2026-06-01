---
title: Configure data lifecycle
sidebar_label: Data lifecycle
sidebar_position: 3
description: Add tiering, retention, and tiered retention policies so old data tiers to Unity Catalog and eventually drops.
---

# Configure data lifecycle

LakeTS gives you three policy primitives for old data: **tiering** (evict to a Unity Catalog Managed Table), **retention** (drop partitions), and **tiered retention** (compose the two).

## Tiering — evict cold data out of Lakebase

A tiering policy marks chunks older than `p_after` for eviction. The data is
already in the Unity Catalog Managed Table via Lakebase CDF; the policy's job is
to free Lakebase storage by dropping the old partitions once the data is safely
cold.

```sql
SELECT lakets.add_tiering_policy('metrics', '7 days');
```

The drop runs in the Databricks Tiering Job (daily 2 AM). A partition is only
dropped once CDF has confirmed its data is durable in Unity Catalog.

## Retention — drop old chunks entirely

A retention policy drops chunks older than `p_after` from Lakebase. No tiering — the data is gone (from Lakebase) once it ages out.

```sql
SELECT lakets.add_retention_policy('metrics', '30 days');
```

## Tiered retention — tier then drop

Two-phase lifecycle: tier to the Unity Catalog Managed Table after `p_tier_after`, drop from the cold tier after `p_drop_after`.

```sql
SELECT lakets.add_tiered_retention_policy('metrics', '7 days', '90 days');
```

This is the most common production pattern:

```
Day 0-7:    HOT   — Lakebase, sub-10ms reads
Day 7-90:   COLD  — Unity Catalog Managed Table, federation queries
Day 90+:    GONE  — retention drops both tiers
```

:::tip RollUps survive retention
You can drop all raw data older than 30 days while keeping your hourly/daily RollUp Tables forever. Aggregates are tiny compared to raw data, and RollUps are stored separately in `_rollup_*` tables.
:::

See [How Tiering & Retention Works](../guides/how-it-works/tiering-and-retention.md) for the internals, including the CDF durability gate.
