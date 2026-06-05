---
title: Quickstart
sidebar_label: Quickstart
sidebar_position: 1
description: Install LakeTS, create your first ChronoTable, and run your first time-series query in 5 minutes.
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Quickstart

Install LakeTS on a Lakebase instance, create a ChronoTable, run your first time-series query. The whole flow takes about five minutes.

## Prerequisites

- A Databricks workspace with Lakebase enabled
- A Lakebase **autoscale** instance running **PostgreSQL 16 or later** (LakeTS is not supported on provisioned instances or earlier Postgres versions)
- A PostgreSQL client (`psql`, DBeaver, or any Postgres-compatible tool)

## 1. Install LakeTS

Pick the install path that matches how you got the LakeTS code. All three paths produce the same end state.

<Tabs groupId="install-method">
<TabItem value="release" label="From a release artifact (recommended)" default>

Download the signed single-file release, verify it, then run it against your Lakebase instance:

```bash
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql
curl -LO https://github.com/databricks-solutions/lakets/releases/latest/download/lakets.sql.sha256
sha256sum -c lakets.sql.sha256

psql -q -h <your-lakebase-host> -U <user>@databricks.com -d <database> -f lakets.sql
```

</TabItem>
<TabItem value="clone" label="From a git clone">

Clone the repo and run the bundled single-file installer:

```bash
git clone https://github.com/databricks-solutions/lakets.git
cd lakets

psql -q -h <your-lakebase-host> -U <user>@databricks.com -d <database> -f dist/lakets.sql
```

</TabItem>
<TabItem value="source" label="From source (all modules)">

If you want to install module-by-module (e.g. to skip optional modules), run the top-level installer that loads each `sql/NN_*.sql` file in order:

```bash
git clone https://github.com/databricks-solutions/lakets.git
cd lakets

psql -q -h <your-lakebase-host> -U <user>@databricks.com -d <database> -f sql/99_install.sql
```

</TabItem>
</Tabs>

Verify the install:

```sql
SELECT version, installed_at, modules FROM lakets._version
ORDER BY installed_at DESC LIMIT 1;
```

## 2. Create your first ChronoTable

A **ChronoTable** is a time-partitioned table — LakeTS's core abstraction for time series data.

<Tabs groupId="table-shape">
<TabItem value="single" label="Single-metric" default>

```sql
CREATE TABLE metrics (
    time    TIMESTAMPTZ NOT NULL,
    device  TEXT NOT NULL,
    cpu     DOUBLE PRECISION,
    memory  DOUBLE PRECISION
);

INSERT INTO metrics
SELECT now() - (i || ' minutes')::interval, 'sensor_' || (i % 10),
       50 + 30 * sin(i::float / 100), 40 + 20 * cos(i::float / 200)
FROM generate_series(1, 10000) AS s(i);

-- Convert to a ChronoTable with 1-day partitions
SELECT lakets.create_chronotable('metrics', 'time', '1 day');
```

</TabItem>
<TabItem value="multi" label="Multi-metric (tags + fields)">

```sql
-- Creates the table + ChronoTable + composite + BRIN indexes in one call
SELECT lakets.create_metric_table(
    'system_metrics',
    tag_columns    := ARRAY['host', 'region', 'env'],
    field_columns  := ARRAY['cpu', 'memory', 'disk_io'],
    chunk_interval := '1 day'
);

INSERT INTO system_metrics (time, host, region, env, cpu, memory, disk_io)
VALUES (now(), 'web-01', 'us-west-2', 'prod', 72.5, 4096, 234.5);
```

</TabItem>
</Tabs>

Check the partitions:

```sql
SELECT * FROM lakets.show_chunks('metrics');
```

## 3. Run your first time-series query

Aggregate by arbitrary intervals with `time_bucket`:

```sql
SELECT
    lakets.time_bucket('1 hour'::interval, time) AS hour,
    device,
    avg(cpu)    AS avg_cpu,
    max(memory) AS max_mem
FROM metrics
WHERE time > now() - interval '1 day'
GROUP BY 1, 2
ORDER BY 1 DESC;
```

Get the first and last reading per device with `lakets.first` / `lakets.last`:

```sql
SELECT
    device,
    lakets.first(cpu, time) AS first_reading,
    lakets.last(cpu, time)  AS latest_reading
FROM metrics
GROUP BY device;
```

That's the core LakeTS loop: a single table call turned a regular Postgres table into a time-partitioned ChronoTable, and standard SQL queries now use time-aware functions automatically.

## What's next

A typical LakeTS deployment progresses through three phases. Work through them in order; each step uses the work from the previous step.

### Phase 1 — model your data

You already created your first ChronoTable above. Before touching anything else, finalize the table shape:

- If your writes carry tags + fields (host, region, env, cpu, memory), use [`create_metric_table`](../reference/multi-metric-tables.md) for a multi-metric ChronoTable
- Confirm tag cardinality is sane — see [Manage tag cardinality](../how-to/cardinality.md) before you scale ingest
- Pick a chunk interval that matches your retention shape (most workloads land on `1 day`)

### Phase 2 — decide where data lives over time

This is the most important step and the easiest one to skip. Choose retention and tiering policies *before* you accumulate data:

- **Hot only** — keep everything in Lakebase. Add a [retention policy](../how-to/lifecycle.md#retention--drop-old-chunks-entirely) so old chunks drop.
- **Hot + cold** — recent data in Lakebase, history in Unity Catalog. Set up [Lakebase CDF](./lakebase-cdf-setup.md) for hot-to-cold sync and a [tiered retention policy](../how-to/lifecycle.md#tiered-retention--tier-then-retain) for the lifecycle.

### Phase 3 — build your read patterns

Now you can think about how the application or dashboard reads the data:

- **Dashboards over recent data** — define [RollUps](../how-to/rollups.md) so dashboards don't re-scan raw rows
- **"What's the current value?" widgets** — turn on the [Last Value Cache](../how-to/last-value-cache.md) for sub-10ms reads
- **Long-window queries** — query the cold tier directly in Databricks (Spark / Databricks SQL)
- **Real-time alerts** — add [threshold and deadman alerts](../how-to/alerts.md)
- **High-throughput writes** — use [`ingest_batch`](../how-to/bulk-ingest.md) instead of per-row inserts
- **Cross-team analytics** — [sync RollUps to Unity Catalog](../how-to/export-to-uc.md) via Lakebase CDF so Spark, BI, and ML can read them
- **Observability of LakeTS itself** — see [Monitoring](../how-to/monitoring.md)

### Reference + further reading

- [How It Works](./how-it-works/index.md) — the internals of ChronoTables, RollUps, and Lakebase CDF
- [Reference](../reference/index.md) — full catalog of 69 functions, 2 aggregates, 6 triggers, 8 metadata tables — organized by topic
- [Troubleshooting](../troubleshooting.md) — when something doesn't behave the way you expect
- [Databricks workflows](https://github.com/databricks-solutions/lakets/blob/main/databricks/bundles/databricks.yml) — automated partition management, tiering, retention, and aggregate refresh
