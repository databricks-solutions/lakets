---
title: Troubleshooting
sidebar_label: Troubleshooting
sidebar_position: 90
description: Common errors, performance pitfalls, and CDF sync gotchas — and how to fix them.
---

# Troubleshooting

The shortlist of things that bite people most often, and how to fix each one.

## Installation

### `ERROR: extension "wal2delta" is not available`

LakeTS is pure SQL — it does not require `wal2delta` to install. You only need `wal2delta` if you're enabling Lakebase CDF. If you saw this error during install:

- Confirm you ran `dist/lakets.sql` (single-file install) or `sql/99_install.sql` (from source) and nothing else
- If you ran a CDF-setup script by mistake, see [Lakebase CDF Setup](./guides/lakebase-cdf-setup.md) for prerequisites

### `ERROR: permission denied to create extension`

You need superuser-equivalent privileges in your Lakebase instance. Connect with the database admin role provided in your Databricks workspace, not a read-only role.

## ChronoTables

### `lakets.create_chronotable()` is slow on existing data

LakeTS has to copy every row from the original table into the new partitioned table. For 100M+ rows, this can take several minutes — the cost is paid once.

To speed it up:

- Add a temporary index on the time column before calling `create_chronotable`
- Run during off-peak hours
- Or use `create_metric_table()` from the start so you skip the conversion step

### Queries are still scanning every chunk

Partition pruning only works if your `WHERE` clause uses the time column in a form Postgres can use. Check for these traps:

- `WHERE time::text LIKE '2026-03%'` — string cast, pruning skipped → use `time >= '2026-03-01' AND time < '2026-04-01'`
- `WHERE date_trunc('day', time) = '2026-03-25'` — function on the column, pruning skipped → use `time >= '2026-03-25' AND time < '2026-03-26'`
- `WHERE time = my_var` where `my_var` is `TEXT` — implicit cast, pruning may skip → ensure `my_var::TIMESTAMPTZ`

Confirm with `EXPLAIN (ANALYZE)` — the plan should list only the chunks you expect.

### Partition Manager fails with `duplicate key value violates unique constraint "idx_chunk_metadata_chunk_name"`

Fixed in **v0.1.3**. Before that, `_ensure_partitions` derived `chunk_name` from `range_start` in the **session timezone**, while `range_start` is stored as an absolute `timestamptz`. Running it from sessions in different timezones (e.g. the scheduled job in UTC and a client in UTC+2) named the same chunk differently, so a later run computed a name that collided with an existing row whose `range_start` differed — and the insert's `ON CONFLICT (chronotable_id, range_start)` couldn't absorb a `chunk_name` collision.

To resolve:

1. Upgrade to v0.1.3+ (reinstall `dist/lakets.sql`) — chunk names are now rendered from the UTC instant, so they stay 1:1 with `range_start` regardless of session timezone.
2. Drop the stale rows created under the old behavior. Their partitions are already gone, so the metadata rows are just colliding tombstones:
   ```sql
   DELETE FROM lakets._chunk_metadata cm
   USING lakets._chronotable_registry hr
   WHERE cm.chronotable_id = hr.id
     AND hr.table_name = '<your_table>'
     AND cm.status = 'dropped'
     AND cm.chunk_name <> hr.schema_name || '.' || hr.table_name || '_'
                          || to_char(cm.range_start AT TIME ZONE 'UTC', 'YYYYMMDD_HH24MISS');
   ```
3. Re-run the Partition Manager — it recreates the missing chunks with UTC-aligned names.

## RollUps

### `refresh_rollup()` returns `FALSE`

The refresh was skipped because not enough time has passed since the last refresh. Check the `refresh_lag` column in `_rollup_registry` — by default it's `15 minutes`. Lower it for development:

```sql
UPDATE lakets._rollup_registry SET refresh_lag = '1 minute' WHERE rollup_name = 'metrics_hourly';
```

### Real-time view returns stale data

The real-time view is `RollUp Table UNION ALL (raw query above watermark)`. If you forgot to add `WHERE time > lakets._rollup_watermark('<rollup_name>')` to the raw side, the view will double-count buckets. Re-create with `create_rollup_view` and confirm the predicate is present.

### Dependency cycle detected

`refresh_rollup_cascade` performs cycle detection via Kahn's algorithm. If you see this error, two RollUps have circular `depends_on` references. Inspect with:

```sql
SELECT rollup_name, depends_on FROM lakets._rollup_registry;
```

Break the cycle by dropping one of the dependencies (`UPDATE _rollup_registry SET depends_on = '{}'`).

## Lakebase CDF

### `_shadow_<table>` is empty in Unity Catalog

CDF only syncs rows that arrive **after** the shadow table is created. Backfill the existing data manually after enabling sync:

```sql
INSERT INTO _shadow_metrics SELECT * FROM metrics;
```

Then re-enable sync from the Databricks UI.

### Schema change broke the sync

Lakebase CDF is schema-sensitive. After an `ALTER TABLE`:

- Stop the sync in the Databricks UI
- Drop the shadow table and trigger: `SELECT lakets.disable_sync('metrics')`
- Re-enable: `SELECT lakets.enable_sync('metrics')`
- Re-run the sync setup

### `wal2delta` complains about partitioned tables

You enabled sync on the ChronoTable itself instead of the shadow table. Make sure `_chronotable_registry.sync_enabled = true` and the registry's `shadow_table_name` is what's configured in the Databricks sync — not the partitioned parent.

### `ERROR: permission denied for schema wal2delta`

`wal2delta` is the Lakebase CDF subsystem's own schema. `enable_sync` and the tiering durability gate probe it only to check whether CDF is active; they never write to it. If your role lacks `USAGE` on `wal2delta`, the probe is tolerated — `enable_sync` completes (creating the shadow and trigger as usual) and the tiering gate fails closed (it evicts nothing it cannot verify).

If you need CDF-gated tiering to actually evict partitions, grant the role read access to the gate it depends on:

```sql
GRANT USAGE ON SCHEMA wal2delta TO "<your-role>";
GRANT SELECT ON wal2delta.tables TO "<your-role>";
```

Run these as the `wal2delta` owner or a Lakebase admin. Until then, tiering stays fail-closed by design.

## Performance

### Inserts slow down over time

Possible causes:

- **Index on a high-cardinality field column** — drop it, indexes on tag columns + time are usually enough
- **Too-fine chunk interval** — `1 hour` partitions create 8,760 chunks per year; switch to `1 day` unless you genuinely need hourly drops
- **No retention policy** — chunks accumulate forever. Add `add_retention_policy()` or `add_tiered_retention_policy()`

### Dashboards still slow with a RollUp

The dashboard might be querying the **raw ChronoTable** instead of the RollUp Table. Verify the query uses `_rollup_<name>` or `_rollup_rt_<name>`, not the base table.

### Cardinality alarms

If `cardinality_stats` shows a column at >10% of total rows, that column is acting like a primary key. See [Manage tag cardinality](./how-to/cardinality.md) for fixes.

## Where to get help

- Open an issue: [github.com/databricks-solutions/lakets/issues](https://github.com/databricks-solutions/lakets/issues)
- Discussions: [github.com/databricks-solutions/lakets/discussions](https://github.com/databricks-solutions/lakets/discussions)
- See the [Glossary](./glossary.md) if a term in the error message is unfamiliar
