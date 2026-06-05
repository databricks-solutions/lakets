---
title: RollUps
sidebar_label: RollUps
sidebar_position: 3
description: Functions for the incremental RollUp engine — creation, refresh, DAG cascade, real-time views, and scale optimizations.
---

# RollUps

RollUps are pre-computed aggregation tables with **incremental refresh** — only dirty buckets are recomputed, not the entire dataset. This is the core performance optimization that makes LakeTS practical at scale.

**Key design choice**: separate RollUp tables (not materialized views) enable surgical per-bucket refresh and DAG-based cascade refresh.

## `create_rollup(p_name, p_query, p_bucket_interval, p_source_table, p_source_schema, p_depends_on)`

Creates a RollUp — a pre-computed aggregation table populated by running the provided query.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Unique RollUp name |
| `p_query` | TEXT | — | Aggregation query (must produce a time bucket column) |
| `p_bucket_interval` | INTERVAL | `'1 hour'` | Time bucket width |
| `p_source_table` | TEXT | `NULL` | Source ChronoTable (for invalidation tracking) |
| `p_source_schema` | TEXT | `'public'` | Source table schema |
| `p_depends_on` | TEXT[] | `'{}'` | Names of prerequisite RollUps for cascade refresh |

**Returns**: `INT` — rollup_id

**What happens internally**:
1. Validates the query can execute
2. Creates the RollUp table `_rollup_{name}` with the query's output schema
3. Runs the initial full load
4. Registers in `_rollup_registry` with watermark set to `now()`

```sql
-- Hourly aggregation of sensor data
SELECT lakets.create_rollup(
    'hourly_sensors',
    $$SELECT lakets.time_bucket('1 hour', time) AS bucket,
            device_id,
            avg(temperature) AS avg_temp,
            max(temperature) AS max_temp,
            min(temperature) AS min_temp,
            count(*) AS sample_count
       FROM sensor_data
       GROUP BY 1, 2$$,
    '1 hour',
    'sensor_data'
);

-- Daily rollup that depends on the hourly one
SELECT lakets.create_rollup(
    'daily_sensors',
    $$SELECT lakets.time_bucket('1 day', bucket) AS bucket,
            device_id,
            avg(avg_temp) AS avg_temp,
            max(max_temp) AS max_temp,
            min(min_temp) AS min_temp,
            sum(sample_count) AS sample_count
       FROM public._rollup_hourly_sensors
       GROUP BY 1, 2$$,
    '1 day',
    NULL, 'public',
    ARRAY['hourly_sensors']
);
```

## `refresh_rollup(p_name)`

Incrementally refreshes a RollUp by recomputing only dirty buckets from the invalidation log.

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_name` | TEXT | RollUp name |

**Returns**: `BOOLEAN` — `TRUE` if refreshed, `FALSE` if skipped (no dirty buckets or within the refresh-lag window)

**Refresh process**:
1. Reads dirty buckets from `_rollup_invalidation_log`
2. Applies chunk-skip pruning — skips unchanged chunks
3. Injects time predicates — partition pruning on source scan
4. Batch deletes + inserts dirty buckets — single `DELETE` + `INSERT` instead of row-by-row `UPSERT`
5. Updates the watermark in `_rollup_registry`
6. Clears processed entries from the invalidation log

```sql
SELECT lakets.refresh_rollup('hourly_sensors');
```

## `refresh_rollup_cascade(p_name)`

Refreshes RollUps in **dependency order** using a topological sort. If `p_name` is `NULL`, refreshes all RollUps.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | `NULL` | Root RollUp name, or `NULL` for all |

**Returns**: TABLE

| Column | Type | Description |
|--------|------|-------------|
| `rollup_name` | TEXT | Name of each refreshed RollUp |
| `refreshed` | BOOLEAN | Whether it actually refreshed |
| `refresh_ms` | FLOAT | Time taken in milliseconds |

```sql
SELECT * FROM lakets.refresh_rollup_cascade();
-- hourly_sensors | true  | 245.3
-- daily_sensors  | true  | 89.7
```

## `create_rollup_view(p_name, p_raw_query)`

Creates a real-time `UNION ALL` view that combines pre-computed RollUp data with fresh, unprocessed data since the last watermark.

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_name` | TEXT | RollUp name |
| `p_raw_query` | TEXT | Query for fresh data (should use watermark boundary) |

**Returns**: `VOID`

```sql
SELECT lakets.create_rollup_view(
    'hourly_sensors',
    $$SELECT lakets.time_bucket('1 hour', time) AS bucket,
            device_id,
            avg(temperature) AS avg_temp,
            max(temperature) AS max_temp,
            min(temperature) AS min_temp,
            count(*) AS sample_count
       FROM sensor_data
       WHERE time > lakets._rollup_watermark('hourly_sensors')
       GROUP BY 1, 2$$
);

-- Always up to date
SELECT * FROM lakets._rollup_rt_hourly_sensors
WHERE bucket >= now() - interval '24 hours';
```

## Invalidation

### `enable_rollup_invalidation(p_rollup_name)` / `disable_rollup_invalidation(p_rollup_name)`

Installs (or removes) a per-row trigger on the source ChronoTable that marks dirty buckets in `_rollup_invalidation_log` automatically.

**Returns**: `VOID`

### `invalidate_rollup_range(p_name, p_from, p_to)`

Manually marks a time range as dirty so the next refresh recomputes it. Use after a bulk `COPY` (which bypasses row-level triggers) or a correction to historical data still resident in Lakebase. Buckets whose source partition has been dropped are skipped — they cannot be recomputed, so the RollUp keeps its last value.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | RollUp name |
| `p_from` | TIMESTAMPTZ | — | Start of dirty range |
| `p_to` | TIMESTAMPTZ | — | End of dirty range |

**Returns**: `INT` — number of bucket entries created in the invalidation log

```sql
SELECT lakets.invalidate_rollup_range(
    'hourly_sensors',
    '2026-03-01', '2026-03-31'
);
```

## Inspection

### `show_rollups()`

Lists all registered RollUps with their configuration and status.

**Returns**: TABLE with `name`, `rollup_table`, `realtime_view`, `bucket_interval`, `refresh_lag`, `watermark`, `last_refreshed_at`, `source_table`, `bucket_column`, `depends_on`. The `depends_on` column is `INT[]` — the raw dependency RollUp **IDs** from the registry. Use `show_rollup_dag()` for the dependencies resolved to names.

### `show_rollup_dag()`

Human-readable DAG visualization showing dependency relationships and refresh order. `depends_on_names` resolves the dependency IDs to RollUp names.

**Returns**: TABLE with `rollup_name`, `depends_on_names`, `refresh_order`, `bucket_interval`, `last_refreshed`.

### `drop_rollup(p_name)`

Drops a RollUp and all associated objects (table, real-time view, registry entry, invalidation-log entries, and — if Lakebase CDF sync was enabled — the `lakets_cdf` shadow table and its mirror trigger).

**Returns**: `VOID`

## Scale optimizations

The base engine above handles the core refresh loop. These functions kick in once you're running 100M+ rows or many hierarchical RollUps. They are mostly called internally — you rarely call them yourself.

### Chunk-skip pruning

- **`_touch_chunk_metadata()`** — statement-level trigger that updates `last_modified_at` on `_chunk_metadata` when a partition receives writes
- **`_get_dirty_chunks(p_chronotable_id, p_since)`** — returns only chunks modified since a given timestamp. Used by `refresh_rollup` to skip scanning unchanged partitions entirely

```sql
-- Called internally during refresh; included here for completeness
SELECT * FROM lakets._get_dirty_chunks(1, '2026-04-01 00:00:00+00');
```

### Predicate injection & batch refresh

- **`_inject_time_predicate(p_query_text, p_time_column, p_dirty_from)`** — rewrites the source query to add `WHERE time >= dirty_from`. Validates with `EXPLAIN` first; falls back to original if injection fails
- **`_refresh_buckets_batch(p_rollup_id, p_rollup_table, p_query_text, p_bucket_column, p_dirty_buckets)`** — refreshes all dirty buckets in exactly 2 statements: one `DELETE` + one `INSERT ... WHERE bucket = ANY(array)`
- **`_refresh_buckets_chunked(..., p_chunk_size)`** — splits large dirty bucket sets into chunks (default 100) to avoid planner degradation

### DAG dependencies

- **`_validate_rollup_dependencies()`** — trigger on `_rollup_registry` that prevents self-dependencies and missing references
- **`_build_rollup_dag(p_root_ids)`** — topological sort of the RollUp dependency graph. Raises on circular dependencies

### Bulk-import invalidation

- **`_bulk_import_invalidation()`** — statement-level `AFTER INSERT` trigger using `REFERENCING NEW TABLE` to capture the time range of all inserted rows (including `COPY FROM`)
- **`_detect_bucket_column(p_query_text)`** — auto-detects the time-bucket column name. Returns the first TIMESTAMPTZ or TIMESTAMP column, or `'bucket'` as a fallback

### Lakebase CDF sync

To expose a RollUp to Spark, BI, or ML via Unity Catalog, use the Lakebase CDF sync functions — see [Lakebase CDF reference](./lakebase-cdf.md) and the [how-to guide](../how-to/export-to-uc.md).

### Internal helper

- **`_rollup_watermark(p_name)`** — `STABLE` function that returns the stored watermark timestamp for a RollUp. Used inside real-time view queries as the boundary between pre-computed and fresh data
