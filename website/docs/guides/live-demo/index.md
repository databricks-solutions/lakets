---
title: LakeTS Live Demo
sidebar_label: Overview
sidebar_position: 1
---

An end-to-end, continuously running demo. Synthetic stock ticks stream into a
Lakebase Autoscaling project while Databricks serverless jobs drive partitioning,
dependency-ordered RollUp refresh, durability-gated tiering, and retention. Lakebase
CDF continuously syncs the data to Unity Catalog, and every stage is observable in
real time.

The source lives in [`demo/live/`](https://github.com/databricks-solutions/lakets/tree/main/demo/live).

## Scenario

A trading platform ingests a high-rate tick feed and needs three capabilities at once:

1. **Millisecond reads of the latest price** for every symbol.
2. **Pre-aggregated OHLCV candles** at minute, hour, and day granularity, always current.
3. **Cheap, durable long-term history** in the lakehouse, without keeping every raw
   row in the operational database forever.

LakeTS delivers all three from a single Postgres-compatible surface: the hot tier
(Lakebase) serves the latest values and recent candles, while the cold tier (Unity
Catalog Delta) holds the full history — kept current continuously, and reclaimed from
the hot tier only once the lakehouse has the data.

## Architecture

The demo spans three layers, each handling what it does best.

<img
  src="/img/live-demo-architecture.svg"
  alt="LakeTS Live Demo architecture: stream_ticks ingests into the stock_ticks ChronoTable in the Lakebase hot tier, which feeds the Last Value Cache, the RollUp DAG, and the lakets_cdf shadow; Lakebase CDF syncs the shadow to the Unity Catalog cold tier; serverless jobs drive the hot tier on a schedule."
/>

### Layer 1 — Lakebase / Postgres

Everything that must react **the instant a row is written** lives inside the database
as PL/pgSQL triggers and functions:

- Last Value Cache trigger
- RollUp invalidation trigger
- CDF shadow mirror trigger
- Partition routing
- Time-series functions and the `refresh_rollup_cascade()` / `tier_chunk()` / `execute_retention()` logic

No external dependency is involved — the moment a tick lands, every watcher fires.

### Layer 2 — Databricks Lakeflow Jobs

- Orchestration runs as **Databricks Lakeflow Jobs** on serverless compute. Each job
  wakes on a schedule and calls a LakeTS SQL function — partitioning, RollUp refresh,
  tiering, and retention. In-database scheduling via `pg_cron` is on the Lakebase
  roadmap; once it lands, this orchestration moves inside the database.
- Each job is a thin Python entry point: open one connection, call one function.
- The demo **reuses the exact jobs shipped in `databricks/workflows/`** rather than
  forking them, so it cannot drift from the production code. The only demo-specific job
  is `stream_ticks`.

### Layer 3 — Lakebase CDF

- Lakebase Change Data Feed continuously syncs the unpartitioned shadow table to a
  Unity Catalog Managed Table.
- No pipeline code and no schedule — a managed capability enabled once on the database.

## What to observe

| Signal | Driven by | Cadence |
| --- | --- | --- |
| Ticks written per minute | `stream_ticks` | continuous |
| Active partitions climb | `partition_manager` and the partition router | as time advances |
| Invalidation log fills then drains | write triggers fill it; `rollup_refresh` drains it | drops toward zero each refresh |
| RollUp watermarks advance | `rollup_refresh` via `refresh_rollup_cascade()` | each refresh |
| Latest price per symbol | the LVC trigger, inside Postgres | real time, no job |
| Rows synced to Unity Catalog | Lakebase CDF on the shadow | continuous |
| Active partitions drop | `tiering` and `retention`, after the durability gate | once data ages past the policy thresholds |
