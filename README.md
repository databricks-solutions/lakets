# LakeTS — Time-Series Toolkit for Databricks Lakebase

[![CI Security & Quality Checks](https://github.com/databricks-solutions/lakets/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/databricks-solutions/lakets/actions/workflows/ci.yml)
[![Release](https://github.com/databricks-solutions/lakets/actions/workflows/release.yml/badge.svg)](https://github.com/databricks-solutions/lakets/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/databricks-solutions/lakets?sort=semver&label=release)](https://github.com/databricks-solutions/lakets/releases/latest)
[![License](https://img.shields.io/badge/license-Databricks_DB_License-blue)](./LICENSE.md)
[![PostgreSQL](https://img.shields.io/badge/postgres-17%2B-336791?logo=postgresql&logoColor=white)](#)

LakeTS turns Databricks Lakebase (managed PostgreSQL 17) into a time-series database:
automatic time-based partitioning, incremental RollUps, a last-value cache, policy-driven
lifecycle tiering, and one-call sync to Unity Catalog via Lakebase CDF. It is pure PL/pgSQL —
no custom extensions required — with optional Databricks jobs for scheduled maintenance.

## Install

```bash
# Single-file install (recommended) — from a published release
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql
psql -q -h <host> -U <user> -d <database> -f lakets.sql

# Or from source
git clone https://github.com/databricks-solutions/lakets.git
psql -q -h <host> -U <user> -d <database> -f lakets/sql/99_install.sql
```

## Quick start

```sql
-- Partition a table by time
CREATE TABLE metrics (time TIMESTAMPTZ NOT NULL, device TEXT, cpu FLOAT8);
SELECT lakets.create_chronotable('metrics', 'time', '1 day');

-- Query with time-series functions
SELECT lakets.time_bucket('1 hour'::interval, time) AS hour,
       avg(cpu), lakets.first(cpu, time), lakets.last(cpu, time)
FROM metrics GROUP BY 1 ORDER BY 1;

-- Lifecycle: keep data resident, then drop once it is durable in Unity Catalog
SELECT lakets.add_tiering_policy('metrics', '7 days');
SELECT lakets.add_retention_policy('metrics', '90 days');

-- Mirror to Unity Catalog (Lakebase CDF)
SELECT lakets.enable_sync('metrics');
```

## Documentation

Full documentation is published at **https://databricks-solutions.github.io/lakets/**:

- **[Getting started](https://databricks-solutions.github.io/lakets/guides/getting-started)** — install, create ChronoTables, run your first query.
- **[How it works](https://databricks-solutions.github.io/lakets/guides/how-it-works)** — partitioning, RollUps, tiering, and Lakebase CDF internals.
- **[How-to guides](https://databricks-solutions.github.io/lakets/how-to)** — RollUps, lifecycle, LVC, alerts, bulk ingest, sync to UC, upgrading.
- **[Reference](https://databricks-solutions.github.io/lakets/reference)** — every function, aggregate, trigger, and metadata table.

## Requirements

- Databricks workspace with Lakebase (PostgreSQL 17+)
- For scheduled maintenance jobs: a Databricks serverless runtime with `pip install -r requirements.txt`

## Contributing

PRs to `main` are validated by CI (SQL lint, Python lint, secret scan, unit tests) — see
[`.github/workflows/ci.yml`](./.github/workflows/ci.yml). Licensed under the
[Databricks License](./LICENSE.md).
