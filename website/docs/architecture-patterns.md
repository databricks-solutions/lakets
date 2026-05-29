---
title: Architecture Patterns
sidebar_label: Architecture Patterns
sidebar_position: 1
description: Reference architectures for time-series workloads on Databricks using LakeTS.
---

# Architecture Patterns

Reference architectures for time-series workloads on Databricks, built around LakeTS's hot-cold model.

Pick the pattern that matches your access shape: latency budget, ingest rate, query mix, and retention horizon.

## 1. Hot-cold tiering

LakeTS's signature pattern. Recent data lives in Lakebase (Postgres) for sub-10ms point queries; older data is replicated to a Unity Catalog Managed Table for cheap, long-horizon retention. Lakebase CDF moves rows from hot to cold automatically via CDC.

```
   ingest → [ Lakebase (hot) ]  ──CDC──▶  [ UC Managed Table (cold) ]
            ChronoTable                   Partitioned by day
            last N days, sub-10ms         year+ retention
```

**Use when**:
- Apps need sub-10ms reads on the latest hour/day of data
- BI/analysis runs over weeks or months of history
- You want one query surface (LakeTS routes hot/cold automatically)

**LakeTS pieces**: `ChronoTable`, `lakets.compression_policy`, `lakets.tiering_policy`, Lakebase CDF.

## 2. Streaming ingest → hot tier → rollup

Real-time ingest from Kafka/Kinesis lands in the hot tier. The RollUp engine incrementally aggregates raw rows into 1-minute / 1-hour / 1-day buckets. Each rollup level is exported to a Unity Catalog Managed Table for long-horizon dashboards.

```
   Kafka/Kinesis ──▶ Bulk Ingest ──▶ ChronoTable (raw, hot)
                                        │
                                        ▼
                                    RollUp DAG  ──▶ 1m → 1h → 1d
                                        │
                                        ▼
                               UC Managed Table (each level)
```

**Use when**:
- Ingest rates exceed what dashboards can scan raw
- You need per-minute granularity for "right now" and per-day granularity for "this quarter"
- Late-arriving events need to backfill rollups correctly

**LakeTS pieces**: Bulk Ingest, RollUp engine, `lakets.create_rollup`, Unity Catalog export.

## 3. Pre-aggregated dashboards

Reads dominate writes. Raw data is rolled up on a schedule; dashboards query only the pre-aggregated buckets. The Last Value Cache serves "current state" widgets in sub-10ms.

```
   raw events ─▶ ChronoTable ─▶ RollUp (1m, 5m, 1h) ─▶ Dashboard
                      │
                      └─▶ Last Value Cache ─▶ "Now" widgets
```

**Use when**:
- Dashboards refresh every few seconds and scan ranges, not points
- You need a tiny "current value" surface for status widgets
- Cost matters: a full table scan per dashboard tile is unacceptable

**LakeTS pieces**: RollUp engine, Last Value Cache, `lakets.time_bucket`, `lakets.gapfill`.

## 4. Multi-region / edge ingest

Edge devices or regional apps write into regional Lakebase instances for low-latency capture. Lakebase CDF funnels CDC streams into a central Unity Catalog Managed Table for cross-region analytics and ML.

```
   region-A ─▶ Lakebase-A ─┐
   region-B ─▶ Lakebase-B ─┼─CDC─▶ central UC Managed Table ─▶ cross-region analytics
   edge     ─▶ Lakebase-E ─┘
```

**Use when**:
- Writers are geographically distributed (IoT fleets, regional apps)
- Each region needs sub-10ms local reads
- Global analytics, ML, and BI consolidate on the central UC Managed Table

**LakeTS pieces**: Multi-instance ChronoTables, Lakebase CDF (per region), Unity Catalog Managed Table for cross-region governance.

## How to choose

| Constraint | Pattern |
|---|---|
| Sub-10ms reads on recent data + long retention | [Hot-cold tiering](#1-hot-cold-tiering) |
| High-throughput streaming ingest + multi-grain queries | [Streaming → rollup](#2-streaming-ingest--hot-tier--rollup) |
| Read-heavy dashboards, "current value" widgets | [Pre-aggregated dashboards](#3-pre-aggregated-dashboards) |
| Distributed writers, central analytics | [Multi-region / edge](#4-multi-region--edge-ingest) |

Most production deployments combine 2–3 patterns. Start with hot-cold tiering, layer in rollups when read latency stops meeting SLOs, and add multi-region when write geography forces it.

See also: [How It Works](./guides/how-it-works/index.md), [Lakebase CDF Setup](./guides/lakebase-cdf-setup.md), [Reference](./reference/index.md).
