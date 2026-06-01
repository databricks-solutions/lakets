---
title: Live Demo
sidebar_label: Live Demo
sidebar_position: 1
description: Stand up the LakeTS "living" streaming demo on a Lakebase Autoscaling project — streaming ingest, DAG RollUps, CDF-gated tiering, and Grafana, step by step.
---

# LakeTS Live Demo

A **living** end-to-end demo. Synthetic stock ticks stream into a Lakebase
Autoscaling project while Databricks serverless jobs drive partitioning,
DAG-ordered RollUp refresh, CDF-gated tiering, and retention. Lakebase CDF
continuously replicates the data to Unity Catalog. You watch the whole pipeline
move in real time.

Source lives in [`demo/live/`](https://github.com/databricks-solutions/lakets/tree/main/demo/live).

## What you'll watch happen

| Signal | Driven by | Cadence |
|---|---|---|
| Ticks written / minute | `stream_ticks` continuous job | continuous |
| Active partitions climb | `partition_manager` (5 min) + the RANGE dispatcher | ~every 5 min |
| Invalidation log fill → drain | write triggers fill it; `rollup_refresh` (1 min) drains it | drops to 0 each minute |
| RollUp watermarks advance | `rollup_refresh` via `refresh_rollup_cascade()` (DAG order) | every minute |
| Latest price per symbol | the LVC trigger fires inside Postgres on every insert | real time, no job |
| Rows replicated to Unity Catalog | Lakebase CDF on the `lakets_cdf` shadow | continuous |
| Active partitions drop | `tiering` (5 min) evicts chunks **only after CDF has flushed them** | once data ages past `drop_after` |

## Architecture in one breath

- **Postgres / Lakebase** runs everything synchronous: invalidation + LVC
  triggers, partition routing, the time-series functions, and the
  `refresh_rollup_cascade()` / `tier_chunk()` / `execute_retention()` SQL.
- **Databricks serverless jobs** exist only to *wake up and call* those SQL
  functions on a schedule (Lakebase's allow-list excludes `pg_cron`). The demo
  **reuses the exact maintenance jobs shipped in `databricks/workflows/`** — it
  only adds `stream_ticks`.
- **Lakebase CDF** replicates the unpartitioned shadow in `lakets_cdf` to a Unity
  Catalog Managed Table. No pipeline code, no schedule.

## Prerequisites

1. A **Lakebase Autoscaling project** in your workspace (e.g. `lakets-tiering-test`).
   Note its name — every step takes the project name, not a host.
2. **Lakebase CDF enabled on the `lakets_cdf` schema** of that project. This is a
   one-time Databricks setup and a hard prerequisite — without it the shadow
   won't replicate and tiering will never evict a partition. See
   [Lakebase CDF setup](./lakebase-cdf-setup.md).
3. **LakeTS installed** on the project (`dist/lakets.sql`).
4. **Databricks CLI** (`>= 1.0`) with a profile for the workspace:
   `databricks auth login --host https://<workspace> -p <profile>`.
5. **`psql`** on PATH (to run `setup.sql`).
6. **Podman or Docker** + compose — only for the optional Grafana dashboards.

:::note Authentication
Everything uses **machine-to-machine OAuth** against the Autoscaling project — no
static passwords. The jobs resolve the project's primary read-write endpoint and
mint a short-lived credential per connection (see
[`lakebase_utils.py`](https://github.com/databricks-solutions/lakets/blob/main/databricks/workflows/lakebase_utils.py)).
For `psql` you mint a token yourself (below). Grafana is the one exception — see
[its section](#optional-grafana-dashboards).
:::

## Step 1 — Install LakeTS (if not already)

Mint a short-lived credential and install the schema. Get the endpoint host and a
token:

```bash
PROJECT=lakets-tiering-test
PROFILE=<your-profile>

# Primary read-write endpoint of the production branch
EP=$(databricks postgres list-endpoints \
       projects/$PROJECT/branches/production -p $PROFILE -o json \
     | jq -r '.[] | select(.endpoint_type=="ENDPOINT_TYPE_READ_WRITE") | .name')
HOST=$(databricks postgres get-endpoint "$EP" -p $PROFILE -o json | jq -r '.status.hosts.host')
USER=$(databricks current-user me -p $PROFILE -o json | jq -r '.userName')
export PGPASSWORD=$(databricks postgres generate-database-credential \
                      --json "{\"endpoint\":\"$EP\"}" -p $PROFILE -o json | jq -r '.token')

PG_URL="host=$HOST port=5432 dbname=databricks_postgres user=$USER sslmode=require"

psql "$PG_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql   # from the repo root
```

## Step 2 — Run the demo setup

`setup.sql` is idempotent. It creates `stock_assets`, the `stock_ticks`
ChronoTable (1-hour chunks), the 1min→1hour→1day RollUp DAG, the Last Value Cache,
a tiered-retention policy, and `enable_sync()` (the CDF shadow). It also resets the
invalidation log and LVC so the audience watches them fill from zero.

```bash
psql "$PG_URL" -v ON_ERROR_STOP=1 -f demo/live/sql/setup.sql
```

The summary at the end prints the ChronoTable registry, the pre-created
partitions, the RollUp DAG in refresh order, and the retention policy.

## Step 3 — Deploy the jobs

```bash
cd demo/live/bundle
databricks bundle deploy -t dev \
  --var="lakebase_project=$PROJECT" -p $PROFILE
```

This deploys five serverless jobs: `stream_ticks` (continuous), `partition_manager`
(5 min), `rollup_refresh` (1 min), `tiering` (5 min), and `retention` (15 min). In
`dev` mode they are prefixed `[dev <you>]` and run as you.

For a shared/prod deployment, use the `prod` target and a service principal that
owns a Lakebase Postgres role:

```bash
databricks bundle deploy -t prod \
  --var="lakebase_project=$PROJECT" \
  --var="service_principal_name=<sp-application-id>" -p $PROFILE
```

The `stream_ticks` job is **continuous** and starts immediately.

## Step 4 — Watch it move

Open the jobs in the workspace. Within a minute or two you'll see ticks flowing,
the invalidation log draining each minute, RollUp watermarks advancing, and
partitions accruing. Query the hot tier directly:

```sql
SELECT * FROM lakets.show_chunks('stock_ticks') ORDER BY range_start;
SELECT * FROM public._lvc_stock_ticks ORDER BY symbol;          -- latest price/symbol
SELECT * FROM public._rollup_ohlcv_1min ORDER BY bucket DESC LIMIT 20;
SELECT count(*) FROM lakets_cdf._shadow_stock_ticks;            -- replicating to UC
```

Tiering evicts a hot partition only once its data has aged past `drop_after`
(60 min in the demo) **and** CDF confirms it's flushed to Unity Catalog — so plan
to run the demo for over an hour to see partitions actually drop, or lower
`drop_after` in `setup.sql`.

### Mid-demo knobs

Re-deploy with different variables, or edit the `stream_ticks` job widgets in the
UI and re-run:

| Variable / widget | Effect |
|---|---|
| `symbols_count` | 10 / 100 / 1000 — widens LVC + RollUp cardinality |
| `rows_per_sec` | 1 / 10 / 100 / 1000 — ingest rate |
| `burst_mode` | `on` pushes 10k extra rows every 60s → watch the invalidation log spike |

## Optional: Grafana dashboards

`demo/live/grafana/` ships a local Grafana stack with two datasources: the hot
Lakebase tier (Postgres) and the cold Unity Catalog tier (Databricks SQL). See
[`demo/live/grafana/README.md`](https://github.com/databricks-solutions/lakets/tree/main/demo/live/grafana) for the full wiring.

:::caution Grafana auth differs
Grafana's Postgres datasource can't rotate OAuth tokens, so the **hot-tier**
datasource needs a static login. Enable native Postgres login on the project and
create a role with a password for Grafana to use; the jobs keep using OAuth. The
**cold-tier** datasource uses a Databricks SQL warehouse + a service-principal
token.
:::

## Teardown

```bash
# Remove the jobs
cd demo/live/bundle && databricks bundle destroy -t dev --var="lakebase_project=$PROJECT" -p $PROFILE

# Reset Lakebase state (keeps the lakets schema itself)
psql "$PG_URL" <<'SQL'
  SELECT lakets.disable_sync('stock_ticks');
  SELECT lakets.disable_lvc('stock_ticks');
  SELECT lakets.drop_rollup('ohlcv_1day');
  SELECT lakets.drop_rollup('ohlcv_1hour');
  SELECT lakets.drop_rollup('ohlcv_1min');
  DROP TABLE IF EXISTS stock_ticks CASCADE;
  DROP TABLE IF EXISTS stock_assets CASCADE;
  DELETE FROM lakets._chronotable_registry WHERE table_name='stock_ticks';
SQL
```

The Unity Catalog Managed Table populated by CDF is retained — drop it from
Catalog Explorer if you want a full reset.
