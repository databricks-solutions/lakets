---
title: Workflow jobs
sidebar_label: Workflow jobs
sidebar_position: 14
description: The Databricks Jobs that drive the operational lifecycle of LakeTS.
---

# Workflow jobs

These scheduled Databricks Jobs drive the operational lifecycle of LakeTS. The bundle at [`databricks/bundles/databricks.yml`](https://github.com/databricks-solutions/lakets/blob/main/databricks/bundles/databricks.yml) deploys all of them at once.

All jobs run on **serverless compute** — there is no cluster to provision. Each runs its `databricks/workflows/*.py` file as a `spark_python_task`, and the Python dependencies (`psycopg[binary]`, `databricks-sdk`) are declared per job in the bundle's `environments` block.

| Job | Schedule | What it does |
|-----|----------|--------------|
| **Partition Manager** | Every 6 h | Calls `_ensure_partitions()` — pre-creates future partitions |
| **Tiering** | Daily 2 AM | `_get_chunks_to_tier()` → `tier_chunk()` per candidate — drops cold partitions whose data CDF has flushed to UC (pure Lakebase SQL, no Spark) |
| **Retention** | Daily 3 AM | `execute_retention()` — drops expired chunks in Lakebase and the UC Managed Table |
| **RollUp Refresh** | Every 15 min | `refresh_rollup()` — incremental hot-tier refresh |
| **Cold RollUp Refresh** | On-demand (no fixed schedule) | `refresh_rollup()` with cold-tier dirty buckets, run after cold-tier ETL corrections |

Each job is idempotent and stateless — re-running it cannot corrupt data. Lakebase remains the source of truth for state (registries, watermarks, invalidation log); the jobs read that state and execute against it.

## Authentication & permissions

The jobs connect to Lakebase with **machine-to-machine (M2M) OAuth** — there are no static passwords. Each job runs as a Databricks **service principal**, and the shared helper [`lakebase_utils.py`](https://github.com/databricks-solutions/lakets/blob/main/databricks/workflows/lakebase_utils.py) mints a short-lived Postgres credential for that identity on every connection, following the [psycopg3 connection pattern](https://docs.databricks.com/aws/en/oltp/instances/query/notebook#psycopg3):

```python
cred = w.database.generate_database_credential(
    request_id=str(uuid.uuid4()), instance_names=[instance_name])
# cred.token is used as the Postgres password; it is minted inside connect()
# so any reconnect transparently gets a fresh, non-expired token (~1 h lifetime).
```

You need a service principal to run these jobs, **and that service principal must have permission on the Lakebase instance to perform the operations** the jobs execute (creating/dropping partitions, refreshing RollUps, enforcing retention).

### 1. A service principal executes the jobs

The bundle's **prod** target runs every job as a service principal via `run_as`:

```yaml
# databricks/bundles/databricks.yml
targets:
  prod:
    run_as:
      service_principal_name: ${var.service_principal_name}
```

Deploy with the service principal's application ID:

```bash
databricks bundle deploy -t prod --var="service_principal_name=<sp-application-id>"
```

The service principal must have **indefinitely-lived OAuth (M2M) credentials**; follow [Authorize service principal access to Databricks with OAuth](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m) and [Obtain an OAuth token in a machine-to-machine flow](https://docs.databricks.com/aws/en/oltp/instances/authentication#obtain-an-oauth-token-in-a-machine-to-machine-flow). Inside a Databricks job the SDK resolves this identity automatically; to run a job file **outside** Databricks, supply the same credentials via the standard environment variables:

```bash
export DATABRICKS_HOST="https://<workspace-url>/"
export DATABRICKS_CLIENT_ID="<sp-application-id>"
export DATABRICKS_CLIENT_SECRET="<sp-oauth-secret>"
```

(Requires `databricks-sdk >= 0.56.0`.)

### 2. The service principal needs a Lakebase Postgres role

The OAuth token authenticates as a **Postgres role named after the service principal**. That role must exist on the Lakebase instance and be granted the privileges the jobs use. Connect as a Lakebase admin and grant, for example:

```sql
-- Register the service principal as a Postgres role (Databricks-managed identity)
-- and grant the privileges the maintenance jobs need.
GRANT USAGE, CREATE ON SCHEMA public, lakets TO "<sp-application-id>";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, lakets TO "<sp-application-id>";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lakets TO "<sp-application-id>";

-- Cover objects created later (new partitions, new RollUp tables):
ALTER DEFAULT PRIVILEGES IN SCHEMA public, lakets
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "<sp-application-id>";
```

`CREATE` on `public`/`lakets` lets the Partition Manager add partitions and lets Tiering/Retention drop them; `EXECUTE` on `lakets` functions covers `tier_chunk()`, `_ensure_partitions()`, `refresh_rollup()`, and friends. If your install scripts ran as a different owner, the simplest alternative is to make the service principal the **owner** of the LakeTS objects (or a member of the owning role).

By default the helper uses the running identity (`current_user`) as the Postgres role. If your Lakebase role name differs from the service principal's application ID, override it with the `LAKETS_PG_ROLE` environment variable on the job.
