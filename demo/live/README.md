# LakeTS Live Demo

A **living** end-to-end demo: synthetic ticks stream into a Lakebase Autoscaling
project while Databricks serverless jobs drive partitioning, DAG-ordered RollUp
refresh, CDF-gated tiering, and retention. Lakebase CDF continuously replicates
to Unity Catalog. The audience watches partitions appear, watermarks advance, the
invalidation log fill and drain, and cold partitions evict — in real time.

> **Full step-by-step setup is in the docs:**
> [`website/docs/guides/live-demo.md`](../../website/docs/guides/live-demo.md)
> (published at the Docusaurus site under **Guides → Live Demo**).

## What's here

```
demo/live/
├── sql/setup.sql            ChronoTable + 3-level RollUp DAG + LVC + tiered
│                            retention + enable_sync (CDF). Idempotent.
├── notebooks/stream_ticks.py  Continuous synthetic ingest (psycopg3 + M2M OAuth).
├── bundle/databricks.yml    5 serverless jobs. Reuses the repo's
│                            databricks/workflows/* maintenance jobs; adds stream_ticks.
└── grafana/                 Local Grafana stack — hot (Lakebase) + cold (UC Delta).
```

## How it maps to current LakeTS capabilities

| Layer | Mechanism |
|---|---|
| Ingest | `stream_ticks` notebook → `stock_ticks` ChronoTable |
| Partitioning | `partition_manager` job → `_ensure_partitions()` |
| RollUps | `rollup_refresh` job → `refresh_rollup_cascade()` (DAG order: 1min→1hour→1day) |
| Latest value | `enable_lvc()` trigger (no job) |
| Cold tier | `enable_sync()` → Lakebase CDF shadow in `lakets_cdf` → Unity Catalog |
| Tiering | `tiering` job → `tier_chunk()` drops partitions only after CDF flush (gated) |
| Retention | `retention` job → `execute_retention()` |

All jobs authenticate with **machine-to-machine OAuth** against the Lakebase
Autoscaling project (no static passwords); the maintenance jobs are the exact
files shipped in `databricks/workflows/` — the demo only adds `stream_ticks`.

## Quick deploy (dev)

```bash
cd demo/live/bundle
databricks bundle deploy -t dev \
  --var="lakebase_project=<your-project>" -p <profile>
```

Then run `sql/setup.sql` against the project and start the `stream_ticks` job.
See the docs guide for the CDF prerequisite, Grafana wiring, and teardown.
