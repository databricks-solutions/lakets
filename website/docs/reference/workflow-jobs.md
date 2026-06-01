---
title: Workflow jobs
sidebar_label: Workflow jobs
sidebar_position: 14
description: The Databricks Jobs that drive the operational lifecycle of LakeTS.
---

# Workflow jobs

These scheduled Databricks Jobs drive the operational lifecycle of LakeTS. The bundle at [`databricks/bundles/databricks.yml`](https://github.com/databricks-solutions/lakets/blob/main/databricks/bundles/databricks.yml) deploys all of them at once.

| Job | Schedule | What it does |
|-----|----------|--------------|
| **Partition Manager** | Every 6 h | Calls `_ensure_partitions()` — pre-creates future partitions |
| **Tiering** | Daily 2 AM | `_get_chunks_to_tier()` → `tier_chunk()` per candidate — drops cold partitions whose data CDF has flushed to UC (pure Lakebase SQL, no Spark) |
| **Retention** | Daily 3 AM | `execute_retention()` — drops expired chunks in Lakebase and the UC Managed Table |
| **RollUp Refresh** | Every 15 min | `refresh_rollup()` — incremental hot-tier refresh |
| **Cold RollUp Refresh** | On-demand (no fixed schedule) | `refresh_rollup()` with cold-tier dirty buckets, run after cold-tier ETL corrections |

Each job is idempotent and stateless — re-running it cannot corrupt data. Lakebase remains the source of truth for state (registries, watermarks, invalidation log); the jobs read that state and execute against it.
