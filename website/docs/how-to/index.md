---
title: How-to guides — Overview
sidebar_label: Overview
sidebar_position: 0
description: Task-oriented guides for everything beyond the Quickstart.
---

# How-to guides

The Quickstart gets you to "LakeTS is running and I ran my first query". From there, each how-to guide solves a specific problem.

Pick the task you need to do — every page is self-contained:

- **[Set up RollUps](./rollups.md)** — pre-compute aggregations so dashboards don't re-scan raw data; cascade refreshes through a dependency DAG.
- **[Last Value Cache](./last-value-cache.md)** — sub-10ms reads for status widgets and "current value" tiles.
- **[Bulk ingest](./bulk-ingest.md)** — write batches from edge devices, protocol adapters, or other writers using the JSONB ingest function.
- **[Alerts](./alerts.md)** — SQL-native threshold and deadman alerts that run inside Lakebase.
- **[Data lifecycle](./lifecycle.md)** — add compression, retention, and tiered retention policies so old data tiers to Unity Catalog and eventually drops.
- **[Monitoring](./monitoring.md)** — query operational metrics, chunk health, and top queries from inside Lakebase.
- **[Manage tag cardinality](./cardinality.md)** — track distinct tag values to prevent label explosion in multi-metric ChronoTables.
- **[Export to Unity Catalog](./export-to-uc.md)** — make RollUp Tables visible to Spark, BI, and ML pipelines.
- **[Downsampling pipelines](./downsampling.md)** — register multi-resolution rollup plans executed by Databricks Jobs.

If you're looking for the internals behind any of these, see **[How It Works](../guides/how-it-works/index.md)**. For full function signatures, see the **[Reference](../reference/index.md)**.
