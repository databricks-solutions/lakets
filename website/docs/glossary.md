---
title: Glossary
sidebar_label: Glossary
sidebar_position: 100
description: Definitions for the terms LakeTS docs use throughout — ChronoTable, watermark, invalidation log, shadow table, and more.
---

# Glossary

Terms used throughout the LakeTS docs, in alphabetical order.

## ChronoTable

A time-partitioned Postgres table managed by LakeTS. Looks like a regular table but is internally split into many smaller **chunks**, one per time interval. Created with `lakets.create_chronotable()` or `lakets.create_metric_table()`.

See [How ChronoTables Work](./guides/how-it-works/chronotables.md).

## Chunk

A single time-range partition of a ChronoTable. Named like `metrics_20260325_000000` (the parent ChronoTable plus the start timestamp of the chunk's time window). Postgres prunes chunks at query time when the `WHERE` clause filters on the time column.

## Cold tier

Where data lives after it ages out of Lakebase: a **Unity Catalog Managed Table**. Optimized for cheap long-horizon retention and analytics scans rather than sub-millisecond reads.

## DAG (RollUp DAG)

The dependency graph between RollUps. A daily RollUp typically depends on an hourly one, which depends on raw data. `refresh_rollup_cascade()` traverses the DAG in topological order so downstream RollUps never read stale upstream data.

## Field column

In a multi-metric ChronoTable, a column holding a measurement (`cpu`, `memory`, `disk_io`). Contrast with **tag column**.

## Gap-fill

The process of inserting placeholder rows for time buckets where no data arrived. LakeTS provides `time_bucket_gapfill()` and `locf()` for this.

## Hot tier

Where recent data lives: **Lakebase** (Postgres). Optimized for sub-10ms reads.

## Hypertable

Synonym for ChronoTable. The `create_hypertable()` alias exists for compatibility with TimescaleDB-shaped code.

## Incremental refresh

The default RollUp refresh mode. Only buckets that received new data (the **dirty window**) are recomputed, instead of rebuilding the whole RollUp table. Driven by a **watermark** and an **invalidation log**.

## Invalidation log

A table (`_rollup_invalidation_log`) that records every bucket whose source data changed since the last refresh. The trigger system upserts entries on every write to a ChronoTable; `refresh_rollup()` consumes them on the next refresh and clears the log.

## Lakebase

Databricks's managed Postgres service. The hot-tier home for LakeTS data.

## Lakebase CDF

Lakebase Change Data Feed — the CDC pipeline that streams row-level changes from Lakebase into a Unity Catalog Managed Table. Implemented underneath via `wal2delta`. See [Lakebase CDF Setup](./guides/lakebase-cdf-setup.md).

## Last Value Cache (LVC)

A trigger-maintained table holding the most recent row per key for a ChronoTable. Used to answer "current value" queries in sub-10ms. See [Last Value Cache](./how-to/last-value-cache.md).

## Multi-metric table

A ChronoTable shaped with `tag_columns` (identifying the series) and `field_columns` (the measurements). InfluxDB-style. Created with `lakets.create_metric_table()`.

## Partition pruning

Postgres's optimization where it skips reading chunks whose time range doesn't overlap the query's `WHERE` clause. The reason ChronoTable queries are fast.

## RollUp

A pre-computed, incrementally-maintained aggregation table. Defined by an aggregation query + bucket interval. The RollUp Table (`_rollup_<name>`) holds the materialized aggregates; the real-time view (`_rollup_rt_<name>`) unions it with fresh data above the watermark.

See [How RollUps Work](./guides/how-it-works/rollups.md).

## Shadow table

An unpartitioned `_shadow_<table>` that mirrors writes from a partitioned ChronoTable. Required because Lakebase CDF can't replicate partitioned tables directly. Created automatically by `lakets.enable_sync()`.

## Tag column

In a multi-metric ChronoTable, a column that identifies a series (`host`, `region`, `env`). Tag combinations should stay below ~10,000 distinct values; see [Cardinality](./how-to/cardinality.md).

## Tiered retention

Two-phase lifecycle policy: tier to the Unity Catalog Managed Table after age N, drop entirely after age M. Configured with `add_tiered_retention_policy()`.

## Unity Catalog Managed Table

Databricks's governed table format that abstracts the underlying storage (Delta or Iceberg). LakeTS uses it as the cold tier — `lakets.enable_sync()` and `lakets.enable_rollup_export()` both target a Unity Catalog Managed Table.

## Watermark

The `bucket_start` of the most recent fully-materialized time bucket in a RollUp Table. Stored in `_rollup_registry.watermark`. Refresh writes all buckets `>= watermark - safety` and then advances the watermark.

## wal2delta

The Postgres extension that captures WAL changes and streams them to the cold tier. The implementation detail that powers Lakebase CDF.
