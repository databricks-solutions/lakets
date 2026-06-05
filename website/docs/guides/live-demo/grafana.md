---
title: Grafana
sidebar_label: Grafana
sidebar_position: 7
---

The [Live Demo](./index.md) ships a local Grafana stack that visualizes both
tiers at once: the **hot tier** straight from Lakebase over Postgres, and the
**cold tier** from the Unity Catalog Managed Table over a Databricks SQL warehouse.

The stack lives in
[`demo/live/grafana/`](https://github.com/databricks-solutions/lakets/tree/main/demo/live/grafana)
and runs in one container via `docker-compose`.

Set up the demo first (after [Deploy & run](./deploy-and-run.md)) so
there is data to chart.

---

## What you get

- **Two datasources**, provisioned automatically from `provisioning/datasources/`:
  - **Lakebase** — the Postgres datasource, querying `stock_ticks`, the Last Value
    Cache, the RollUp tables, `lakets.show_chunks`, and the invalidation log.
  - **Databricks** — the cold tier, querying the Unity Catalog Managed Table that
    Lakebase CDF syncs from `lakets_cdf._shadow_stock_ticks`.
- **Three dashboards**, provisioned from `dashboards/`:
  - `lakets_live.json` — hot tier, fast refresh.
  - `lakets_cold_tier.json` — cold tier (Unity Catalog).
  - `lakets_continuum.json` — hot and cold side by side.

---

## The auth model (read this first)

The two tiers authenticate differently, and the hot tier is the subtle one:

- **Hot tier (Lakebase / Postgres)** — Grafana's Postgres datasource **cannot rotate
  OAuth tokens**, and Lakebase Autoscaling OAuth tokens expire roughly hourly. So the
  hot-tier datasource needs a **static native Postgres login** — a dedicated role
  with a password. The maintenance jobs keep using OAuth; only Grafana uses the
  native login.
- **Cold tier (Unity Catalog)** — uses a **Databricks SQL warehouse** plus a token.
  Prefer a **service-principal-owned token**, so the lakehouse audit log attributes
  Grafana's queries to the service principal rather than to a person.

The cold tier is optional. Leave its variables blank and only the hot-tier dashboard
works; come back and wire it up later.

---

## Step 1 — Enable native Postgres login (hot tier)

Native login is an additional auth method on the project; enabling it does not affect
the OAuth the jobs use.

```bash
databricks postgres update-project projects/<your-project> \
  --json '{"spec":{"enable_pg_native_login":true}}' -p <your-cli-profile>
```

Then, connected as a Lakebase admin (see [Setup](./setup.md)
for the `psql` connection), create a least-privilege role for Grafana:

```sql
CREATE ROLE grafana LOGIN PASSWORD '<strong-password>';

GRANT USAGE   ON SCHEMA public, lakets             TO grafana;
GRANT SELECT  ON ALL TABLES    IN SCHEMA public, lakets TO grafana;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lakets    TO grafana;

-- Cover tables created later (new partitions, new RollUp tables):
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO grafana;
```

The Postgres host is the project's primary read-write endpoint host — the same
`$HOST` you resolved in the Live Demo guide.

---

## Step 2 — Gather the cold-tier inputs (optional)

For the Unity Catalog dashboard you need:

- a **Databricks SQL warehouse** the token can use (`CAN_USE`),
- its **HTTP path** and the **workspace host**,
- a **token** — ideally owned by a service principal that has `USE_CATALOG` /
  `USE_SCHEMA` / `SELECT` on the destination catalog and schema,
- the **Unity Catalog table** that CDF syncs into (catalog, schema, table name).

Skip this step to run the hot-tier dashboard only.

---

## Step 3 — Configure the environment

In `demo/live/grafana/`, prepare a `.env` file as follows. Fill in the hot-tier values
for your project; leave the cold-tier block blank to run only the hot-tier dashboard.

```bash
# --- Grafana ---
GRAFANA_PORT=3030
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=<grafana-admin-password>

# --- Lakebase hot tier (Postgres datasource) ---
# LAKEBASE_HOST = the project's primary read-write endpoint host (the same $HOST
# you resolved in Setup).
LAKEBASE_HOST=ep-xxxxxxxx.database.<region>.cloud.databricks.com
LAKEBASE_PORT=5432
LAKEBASE_DATABASE=databricks_postgres
LAKEBASE_USER=grafana
LAKEBASE_PASSWORD=<grafana-role-password>      # the grafana role + password from Step 1

# --- Databricks SQL cold tier (UC Delta) — optional ---
# DELTA_TABLE = the Unity Catalog Managed Table that Lakebase CDF syncs the
# lakets_cdf._shadow_stock_ticks shadow into.
DATABRICKS_HOST=
DATABRICKS_HTTP_PATH=
DATABRICKS_TOKEN=
DATABRICKS_CATALOG=
DATABRICKS_SCHEMA=
DELTA_TABLE=
```

---

## Step 4 — Start Grafana

```bash
podman compose --env-file .env up -d    # or: docker compose --env-file .env up -d
```

- Open **http://localhost:3030** (anonymous Viewer access is enabled).
- Both datasources and all three dashboards are provisioned on first boot.

The cold-tier datasource (`mullerpeter-databricks-datasource`) was delisted from the
Grafana catalog but is still maintained, so `docker-compose.yml` installs it from its
GitHub release via `GF_INSTALL_PLUGINS` and allows it to load unsigned.

To stop it:

```bash
podman compose down                      # or: docker compose down
```
