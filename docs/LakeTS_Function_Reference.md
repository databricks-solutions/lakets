# LakeTS v0.1.1 — Complete Function Reference

## Technical Deep-Dive for Engineers & Solution Architects

LakeTS is a pure-SQL time series toolkit for Databricks Lakebase (PostgreSQL 16+). It provides 77 functions, 2 custom aggregates, 6 trigger functions, and 9 metadata tables — all within the `lakets` schema. No custom extensions required.

**Architecture**: Hot tier (Lakebase/PostgreSQL) + cold tier (Delta Lake) hybrid, with automatic tiering, incremental rollups, and Unity Catalog integration.

---

## Table of Contents

1. [ChronoTable Management](#1-chronotable-management)
2. [Time Series Analytics](#2-time-series-analytics)
3. [RollUp Aggregation Engine](#3-rollup-aggregation-engine)
4. [RollUp Optimization (M23–M28)](#4-rollup-optimization-m23m28)
5. [Compression & Tiering](#5-compression--tiering)
6. [Retention Policies](#6-retention-policies)
7. [Monitoring & Observability](#7-monitoring--observability)
8. [Shadow Sync (Lakehouse Sync)](#8-shadow-sync-lakehouse-sync)
9. [Multi-Metric Tables](#9-multi-metric-tables)
10. [Last Value Cache (LVC)](#10-last-value-cache-lvc)
11. [Downsampling Pipelines](#11-downsampling-pipelines)
12. [Alerting](#12-alerting)
13. [Bulk Ingest](#13-bulk-ingest)
14. [Unity Catalog Integration](#14-unity-catalog-integration)
15. [Metadata Tables Reference](#15-metadata-tables-reference)

---

## 1. ChronoTable Management

ChronoTables are LakeTS's core abstraction — regular PostgreSQL tables converted to RANGE-partitioned time series tables. Each partition (chunk) covers a fixed time interval and is tracked in `_chronotable_registry` and `_chunk_metadata`.

**Why RANGE partitioning?** Native partition pruning on time predicates, instant `DROP PARTITION` for retention, and automatic insert routing without application logic.

### `create_chronotable(p_table_name, p_time_column, p_chunk_interval, p_schema_name)`

Converts a regular table into a time-partitioned ChronoTable. This is the primary entry point for onboarding any time series table.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Name of the existing table to convert |
| `p_time_column` | TEXT | — | Column used for partitioning (must be TIMESTAMPTZ) |
| `p_chunk_interval` | INTERVAL | `'7 days'` | Size of each partition |
| `p_schema_name` | TEXT | `'public'` | Schema of the table |

**Returns**: `INT` — the chronotable_id assigned in `_chronotable_registry`

**What happens internally**:
1. Validates the table exists and the time column is TIMESTAMPTZ
2. Renames the original table to a temporary name
3. Creates a new partitioned table with `PARTITION BY RANGE (time_column)`
4. Scans existing data to determine the min/max time range
5. Creates partitions covering the full data range plus future partitions
6. Migrates existing data into the partitioned structure
7. Registers the table in `_chronotable_registry` and each partition in `_chunk_metadata`

```sql
-- Create a metrics table, then convert it
CREATE TABLE sensor_data (
    time TIMESTAMPTZ NOT NULL,
    device_id TEXT,
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION
);

-- Convert to ChronoTable with 1-day partitions
SELECT lakets.create_chronotable('sensor_data', 'time', '1 day');
-- Returns: 1 (chronotable_id)
```

### `create_hypertable(p_table_name, p_time_column, p_chunk_interval, p_schema_name, p_if_not_exists)`

The original v1 name for ChronoTable creation. Identical behavior to `create_chronotable` with an additional `p_if_not_exists` parameter.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Table to convert |
| `p_time_column` | TEXT | — | Time column (TIMESTAMPTZ) |
| `p_chunk_interval` | INTERVAL | `'7 days'` | Partition interval |
| `p_schema_name` | TEXT | `'public'` | Schema |
| `p_if_not_exists` | BOOLEAN | `FALSE` | Skip if already a ChronoTable |

**Returns**: `INT` — chronotable_id

### `set_chunk_interval(p_table_name, p_chunk_interval, p_schema_name)`

Changes the partition interval for future partitions. Existing partitions are not affected.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_chunk_interval` | INTERVAL | — | New interval for future partitions |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
-- Switch from 7-day to 1-day partitions going forward
SELECT lakets.set_chunk_interval('sensor_data', '1 day');
```

### `show_chunks(p_table_name, p_older_than, p_newer_than, p_schema_name)`

Lists all partitions for a ChronoTable with metadata. Essential for operational visibility.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_older_than` | INTERVAL | `NULL` | Filter: only chunks older than this |
| `p_newer_than` | INTERVAL | `NULL` | Filter: only chunks newer than this |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: TABLE

| Column | Type | Description |
|--------|------|-------------|
| `chunk_name` | TEXT | Partition name (e.g., `sensor_data_20260401_000000`) |
| `range_start` | TIMESTAMPTZ | Partition lower bound |
| `range_end` | TIMESTAMPTZ | Partition upper bound |
| `status` | TEXT | `active`, `compressed`, `tiered`, or `dropped` |
| `row_count` | BIGINT | Approximate row count |
| `size_bytes` | BIGINT | Partition size on disk |
| `created_at` | TIMESTAMPTZ | When the partition was created |

```sql
-- Show all chunks
SELECT * FROM lakets.show_chunks('sensor_data');

-- Show only chunks older than 30 days
SELECT * FROM lakets.show_chunks('sensor_data', p_older_than => '30 days');
```

### `drop_chunks(p_table_name, p_older_than, p_schema_name)`

Drops partitions older than a given interval. Used for manual cleanup or by the retention system.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_older_than` | INTERVAL | — | Drop partitions older than this |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — number of partitions dropped

```sql
-- Drop data older than 90 days
SELECT lakets.drop_chunks('sensor_data', '90 days');
-- Returns: 12 (dropped 12 partitions)
```

### `_ensure_partitions(p_chronotable_id, p_past_count, p_future_count, p_range_start, p_range_end)`

**Internal function.** Pre-creates partitions for a ChronoTable. Called automatically by `create_chronotable` and by the Databricks Partition Manager job (every 6 hours).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_chronotable_id` | INT | — | ChronoTable registry ID |
| `p_past_count` | INT | `1` | Number of past partitions to ensure |
| `p_future_count` | INT | `3` | Number of future partitions to ensure |
| `p_range_start` | TIMESTAMPTZ | `NULL` | Explicit range start (overrides counts) |
| `p_range_end` | TIMESTAMPTZ | `NULL` | Explicit range end (overrides counts) |

**Returns**: `INT` — number of new partitions created. Idempotent — skips existing partitions.

### `_resolve_partition_parent(p_schema, p_table)`

**Internal function.** Resolves a partition's parent table name from the PostgreSQL inheritance catalog. Used by triggers that fire on individual partitions.

**Returns**: `TEXT` — parent table name

---

## 2. Time Series Analytics

Core analytical functions for time series computation. All are `IMMUTABLE` — safe for use in indexes, generated columns, and parallel queries.

### `time_bucket(p_interval, p_timestamp, p_origin)`

The foundational time series function. Truncates a timestamp to the nearest bucket boundary aligned to an origin point.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_interval` | INTERVAL | — | Bucket width (e.g., `'1 hour'`, `'5 minutes'`, `'1 month'`) |
| `p_timestamp` | TIMESTAMPTZ | — | Timestamp to bucket |
| `p_origin` | TIMESTAMPTZ | `'2000-01-01 00:00:00+00'` | Alignment origin |

**Returns**: `TIMESTAMPTZ`

**Implementation details**:
- Sub-month intervals (seconds, minutes, hours, days, weeks): delegates to PostgreSQL's `date_bin()` for nanosecond precision
- Month/year intervals: uses `date_trunc` + interval arithmetic to handle variable-length months

```sql
-- Hourly buckets
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       avg(temperature) AS avg_temp
FROM sensor_data
WHERE time >= now() - interval '7 days'
GROUP BY 1 ORDER BY 1;

-- 15-minute buckets aligned to epoch
SELECT lakets.time_bucket('15 minutes', time) AS bucket,
       count(*) AS events
FROM events
GROUP BY 1;

-- Monthly aggregation
SELECT lakets.time_bucket('1 month', time) AS month,
       sum(revenue) AS monthly_revenue
FROM transactions
GROUP BY 1 ORDER BY 1;
```

### `first(value, timestamp)` — Custom Aggregate

Returns the value associated with the **earliest** timestamp in the group.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | DOUBLE PRECISION | The value to return |
| `timestamp` | TIMESTAMPTZ | The ordering timestamp |

**Returns**: `DOUBLE PRECISION`

**Internal state type**: `_first_last_state` composite type `(value DOUBLE PRECISION, ts TIMESTAMPTZ)`

**Helper functions**: `_first_sfunc` (state transition), `_first_ffunc` (final extraction)

```sql
-- Get the opening price (first trade) per hour
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       lakets.first(price, time) AS open_price,
       lakets.last(price, time) AS close_price,
       max(price) AS high,
       min(price) AS low
FROM trades
GROUP BY 1;
```

### `last(value, timestamp)` — Custom Aggregate

Returns the value associated with the **latest** timestamp in the group.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | DOUBLE PRECISION | The value to return |
| `timestamp` | TIMESTAMPTZ | The ordering timestamp |

**Returns**: `DOUBLE PRECISION`

**Internal state type**: `_first_last_state` (shared with `first`)

### `time_bucket_gapfill(p_interval, p_start, p_finish)`

Generates a continuous series of time buckets between start and finish. Used with LEFT JOIN to produce gapfilled results where no data exists.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_interval` | INTERVAL | — | Bucket width |
| `p_start` | TIMESTAMPTZ | — | Series start (inclusive) |
| `p_finish` | TIMESTAMPTZ | — | Series end (exclusive) |

**Returns**: `SETOF TIMESTAMPTZ`

```sql
-- Gapfilled hourly temperature readings
SELECT g.bucket, d.avg_temp
FROM lakets.time_bucket_gapfill('1 hour', '2026-04-01', '2026-04-02') AS g(bucket)
LEFT JOIN (
    SELECT lakets.time_bucket('1 hour', time) AS bucket,
           avg(temperature) AS avg_temp
    FROM sensor_data
    WHERE time >= '2026-04-01' AND time < '2026-04-02'
    GROUP BY 1
) d ON d.bucket = g.bucket
ORDER BY g.bucket;
```

### `locf(p_value, p_prev_value)`

**Last Observation Carried Forward.** Fills NULL values with the most recent non-NULL value. Designed for use with window functions over gapfilled series.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value (may be NULL) |
| `p_prev_value` | DOUBLE PRECISION | `NULL` | Previous non-NULL value from window |

**Returns**: `DOUBLE PRECISION` — `p_value` if not NULL, else `p_prev_value`

```sql
-- Fill gaps with last known value
SELECT bucket,
       lakets.locf(
           avg_temp,
           lag(avg_temp) OVER (ORDER BY bucket)
       ) AS filled_temp
FROM gapfilled_data;
```

### `interpolate(p_value, p_prev_value, p_next_value, p_prev_time, p_curr_time, p_next_time)`

**Linear interpolation** between two known data points. Computes value at `p_curr_time` proportional to position between `p_prev_time` and `p_next_time`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value (returned as-is if not NULL) |
| `p_prev_value` | DOUBLE PRECISION | — | Previous known value |
| `p_next_value` | DOUBLE PRECISION | — | Next known value |
| `p_prev_time` | TIMESTAMPTZ | — | Time of previous value |
| `p_curr_time` | TIMESTAMPTZ | — | Time to interpolate at |
| `p_next_time` | TIMESTAMPTZ | — | Time of next value |

**Returns**: `DOUBLE PRECISION`

**Formula**: `prev_value + (next_value - prev_value) * (curr_time - prev_time) / (next_time - prev_time)`

```sql
-- Linear interpolation over gapfilled series
SELECT bucket,
       lakets.interpolate(
           avg_temp,
           lag(avg_temp) OVER w,
           lead(avg_temp) OVER w,
           lag(bucket) OVER w,
           bucket,
           lead(bucket) OVER w
       ) AS interpolated_temp
FROM gapfilled_data
WINDOW w AS (ORDER BY bucket);
```

### `delta(p_value, p_prev_value, p_handle_resets)`

Computes the **difference** between consecutive values. Handles counter resets (where value drops below previous, e.g., restarted process counters).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value |
| `p_prev_value` | DOUBLE PRECISION | — | Previous value |
| `p_handle_resets` | BOOLEAN | `TRUE` | If TRUE, treats negative delta as counter reset (returns current value) |

**Returns**: `DOUBLE PRECISION`

```sql
-- Compute per-interval change in a monotonic counter
SELECT time,
       lakets.delta(
           bytes_sent,
           lag(bytes_sent) OVER (ORDER BY time)
       ) AS bytes_delta
FROM network_stats;
```

### `rate(p_value, p_prev_value, p_time, p_prev_time, p_handle_resets)`

Computes the **rate of change per second** between consecutive points. Essential for monitoring counters.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value |
| `p_prev_value` | DOUBLE PRECISION | — | Previous value |
| `p_time` | TIMESTAMPTZ | — | Current timestamp |
| `p_prev_time` | TIMESTAMPTZ | — | Previous timestamp |
| `p_handle_resets` | BOOLEAN | `TRUE` | Handle counter resets |

**Returns**: `DOUBLE PRECISION` — change per second

```sql
-- Requests per second from a monotonic counter
SELECT lakets.time_bucket('1 minute', time) AS bucket,
       avg(lakets.rate(
           request_count,
           lag(request_count) OVER (PARTITION BY host ORDER BY time),
           time,
           lag(time) OVER (PARTITION BY host ORDER BY time)
       )) AS rps
FROM http_metrics
GROUP BY 1;
```

### `histogram(p_value, p_min, p_max, p_num_buckets)`

Returns a **bucket index** for frequency distribution analysis.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Value to classify |
| `p_min` | DOUBLE PRECISION | — | Histogram lower bound |
| `p_max` | DOUBLE PRECISION | — | Histogram upper bound |
| `p_num_buckets` | INT | — | Number of equal-width buckets |

**Returns**: `INT` — bucket index (0-based), NULL for NULL input, -1 for below min, `p_num_buckets` for above max

```sql
-- Distribution of response times
SELECT lakets.histogram(response_ms, 0, 1000, 10) AS bucket,
       count(*) AS frequency
FROM requests
WHERE time >= now() - interval '1 hour'
GROUP BY 1 ORDER BY 1;
```

---

## 3. RollUp Aggregation Engine

RollUps are pre-computed aggregation tables with **incremental refresh** — only dirty buckets are recomputed, not the entire dataset. This is the core performance optimization that makes LakeTS practical at scale.

**Key design choice**: Separate RollUp tables (not materialized views) enable surgical per-bucket refresh, DAG-based cascade refresh, and hot/cold tier routing.

### `create_rollup(p_name, p_query, p_bucket_interval, p_source_table, p_source_schema, p_refresh_mode, p_depends_on)`

Creates a RollUp — a pre-computed aggregation table populated by running the provided query.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Unique RollUp name |
| `p_query` | TEXT | — | Aggregation query (must produce a time bucket column) |
| `p_bucket_interval` | INTERVAL | `'1 hour'` | Time bucket width |
| `p_source_table` | TEXT | `NULL` | Source ChronoTable (for invalidation tracking) |
| `p_source_schema` | TEXT | `'public'` | Source table schema |
| `p_refresh_mode` | TEXT | `'incremental'` | `'incremental'` or `'full'` |
| `p_depends_on` | TEXT[] | `'{}'` | Names of RollUps this depends on (for DAG cascade) |

**Returns**: `INT` — rollup_id

**What happens internally**:
1. Validates the query can execute
2. Creates the RollUp table `_rollup_{name}` with the query's output schema
3. Runs the initial full load
4. Registers in `_rollup_registry` with watermark set to now()

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
       FROM lakets._rollup_hourly_sensors
       GROUP BY 1, 2$$,
    '1 day',
    NULL, 'public', 'incremental',
    ARRAY['hourly_sensors']
);
```

### `refresh_rollup(p_name)`

Incrementally refreshes a RollUp by recomputing only dirty buckets from the invalidation log.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | RollUp name |

**Returns**: `BOOLEAN` — TRUE if refreshed, FALSE if skipped (no dirty buckets or within refresh_lag window)

**Refresh process**:
1. Reads dirty buckets from `_rollup_invalidation_log`
2. Applies chunk-skip pruning (M23) — skips unchanged chunks
3. Injects time predicates (M24) — partition pruning on source scan
4. Batch deletes + inserts dirty buckets (M27) — single DELETE + INSERT instead of row-by-row UPSERT
5. Updates watermark in `_rollup_registry`
6. Clears processed entries from invalidation log

```sql
SELECT lakets.refresh_rollup('hourly_sensors');
```

### `refresh_rollup_cascade(p_name)`

Refreshes RollUps in **dependency order** using topological sort (M25). If `p_name` is NULL, refreshes ALL RollUps.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | `NULL` | Root RollUp name, or NULL for all |

**Returns**: TABLE

| Column | Type | Description |
|--------|------|-------------|
| `rollup_name` | TEXT | Name of each refreshed RollUp |
| `refreshed` | BOOLEAN | Whether it actually refreshed |
| `refresh_ms` | FLOAT | Time taken in milliseconds |

```sql
-- Refresh everything in DAG order
SELECT * FROM lakets.refresh_rollup_cascade();
-- Returns:
-- hourly_sensors | true  | 245.3
-- daily_sensors  | true  | 89.7
```

### `create_rollup_view(p_name, p_raw_query)`

Creates a **real-time UNION view** that combines pre-computed RollUp data with fresh unprocessed data since the last watermark.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | RollUp name |
| `p_raw_query` | TEXT | — | Query for fresh data (should use watermark boundary) |

**Returns**: `VOID`

```sql
-- Create real-time view
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

-- Query the real-time view — always up to date
SELECT * FROM lakets._rollup_rt_hourly_sensors
WHERE bucket >= now() - interval '24 hours';
```

### `enable_rollup_invalidation(p_rollup_name)`

Installs a per-row trigger on the source ChronoTable that automatically marks dirty buckets in the invalidation log when data is inserted, updated, or deleted.

**Returns**: `VOID`

### `disable_rollup_invalidation(p_rollup_name)`

Removes the invalidation trigger. Use when temporarily disabling incremental tracking (e.g., during large migrations).

**Returns**: `VOID`

### `invalidate_rollup_range(p_name, p_from, p_to, p_tier)`

Manually marks a time range as dirty. Use after bulk COPY operations (which bypass row-level triggers).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | RollUp name |
| `p_from` | TIMESTAMPTZ | — | Start of dirty range |
| `p_to` | TIMESTAMPTZ | — | End of dirty range |
| `p_tier` | TEXT | `NULL` | `'hot'`, `'cold'`, or NULL (auto-detect) |

**Returns**: `INT` — number of bucket entries created in the invalidation log

```sql
-- After a bulk COPY import
SELECT lakets.invalidate_rollup_range(
    'hourly_sensors',
    '2026-03-01', '2026-03-31'
);
```

### `show_rollups()`

Lists all registered RollUps with their configuration and status.

**Returns**: TABLE with columns: `name`, `rollup_table`, `realtime_view`, `bucket_interval`, `refresh_mode`, `refresh_lag`, `watermark`, `last_refreshed_at`, `source_table`, `bucket_column`, `depends_on`, `export_enabled`

### `show_rollup_dag()`

Human-readable DAG visualization showing dependency relationships and refresh order.

**Returns**: TABLE with columns: `rollup_name`, `depends_on_names`, `refresh_order`, `bucket_interval`, `last_refreshed`

### `drop_rollup(p_name)`

Drops a RollUp and all associated objects (table, real-time view, registry entry, invalidation log entries).

**Returns**: `VOID`

### `_rollup_watermark(p_name)`

**Internal function (STABLE).** Returns the stored watermark timestamp for a RollUp. Used inside real-time view queries as the boundary between pre-computed and fresh data.

---

## 4. RollUp Optimization (M23–M28)

Six optimization modules that extend the base RollUp engine for production-grade performance.

### M23: Chunk-Skip Pruning

**`_touch_chunk_metadata()`** — Statement-level trigger that updates `last_modified_at` on `_chunk_metadata` when a partition receives writes.

**`_get_dirty_chunks(p_chronotable_id, p_since)`** — Returns only chunks modified since a given timestamp. Used by `refresh_rollup` to skip scanning unchanged partitions entirely.

```sql
-- Internally called during refresh — only scans partitions with new data
SELECT * FROM lakets._get_dirty_chunks(1, '2026-04-01 00:00:00+00');
```

### M24: Predicate Injection & Batch Refresh

**`_inject_time_predicate(p_query_text, p_time_column, p_dirty_from)`** — Rewrites the source query to add a `WHERE time >= dirty_from` clause for partition pruning. Validates rewritten query with EXPLAIN before use; falls back to original if injection fails.

**`_refresh_buckets_batch(p_rollup_id, p_rollup_table, p_query_text, p_bucket_column, p_dirty_buckets)`** — Refreshes all dirty buckets in exactly 2 SQL statements: one `DELETE` + one `INSERT ... WHERE bucket = ANY(array)`. Eliminates row-by-row UPSERT overhead.

**`_refresh_buckets_chunked(..., p_chunk_size)`** — Splits large dirty bucket sets into chunks of `p_chunk_size` (default 100) to avoid query planner degradation on massive arrays.

### M25: DAG Dependencies

**`_validate_rollup_dependencies()`** — Trigger on `_rollup_registry` that prevents self-dependencies and missing references.

**`_build_rollup_dag(p_root_ids)`** — Topological sort of the RollUp dependency graph. Returns ordered array of rollup IDs. Raises exception on circular dependencies.

### M26: Hot/Cold Tier Routing

**`_resolve_bucket_tier(p_chronotable_id, p_bucket_start)`** — Determines whether a bucket's source data is in the hot tier (Lakebase) or cold tier (Delta Lake) by checking chunk status. Returns `'hot'` or `'cold'`.

### M27: Bulk Import Invalidation

**`_bulk_import_invalidation()`** — Statement-level `AFTER INSERT` trigger using `REFERENCING NEW TABLE` to capture the time range of all inserted rows (including `COPY FROM`). Auto-invalidates affected RollUp buckets without per-row overhead.

**`_detect_bucket_column(p_query_text)`** — Auto-detects the time bucket column name from a RollUp query's output. Returns the first TIMESTAMPTZ column, or `'bucket'` as fallback.

### M28: Delta Export

**`enable_rollup_export(p_rollup_name, p_delta_table, p_export_mode)`** — Enables periodic export of RollUp data to a Delta Lake table. Mode can be `'incremental'` or `'full'`.

**`disable_rollup_export(p_rollup_name)`** — Disables export.

**`show_rollup_exports()`** — Shows export status, lag, and watermark for all export-enabled RollUps.

```sql
-- Enable export of hourly rollup to Delta
SELECT lakets.enable_rollup_export(
    'hourly_sensors',
    'main.lakets_rollups.hourly_sensors',
    'incremental'
);

-- Check export status
SELECT * FROM lakets.show_rollup_exports();
```

---

## 5. Compression & Tiering

Tiering policies move data from the hot tier (Lakebase) to the cold tier (Delta Lake) based on age. The actual data movement is performed by the Databricks Compression & Tiering job (daily at 2 AM).

### `add_compression_policy(p_table_name, p_compress_after, p_segment_by, p_order_by, p_schema_name)`

Registers a tiering policy for a ChronoTable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_compress_after` | INTERVAL | — | Tier chunks older than this |
| `p_segment_by` | TEXT | `NULL` | Column for segment optimization in Delta |
| `p_order_by` | TEXT | `NULL` | Column for Z-order optimization in Delta |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Tier data older than 30 days to Delta, segment by device_id
SELECT lakets.add_compression_policy(
    'sensor_data', '30 days',
    p_segment_by => 'device_id',
    p_order_by => 'time'
);
```

### `compress_chunk(p_chunk_name)` / `decompress_chunk(p_chunk_name)`

Manually mark a specific chunk for tiering to Delta or for re-ingestion from Delta back to Lakebase.

### `show_compression_policy(p_table_name, p_schema_name)`

Returns the compression/tiering policy for a ChronoTable.

**Returns**: TABLE with: `policy_id`, `compress_after`, `segment_by`, `order_by`, `enabled`, `last_run_at`

### `remove_compression_policy(p_table_name, p_schema_name)`

Removes the compression/tiering policy.

### `_get_chunks_to_compress(p_table_name, p_schema_name)`

**Internal function.** Returns chunks eligible for tiering (active chunks older than the `compress_after` threshold). Used by the Databricks Compression & Tiering workflow.

---

## 6. Retention Policies

Automatic data lifecycle management — drop expired data from Lakebase and/or Delta Lake.

### `add_retention_policy(p_table_name, p_drop_after, p_schema_name)`

Simple retention: drops Lakebase partitions older than `p_drop_after`.

**Returns**: `INT` — policy_id

```sql
-- Keep only 1 year of data in Lakebase
SELECT lakets.add_retention_policy('sensor_data', '365 days');
```

### `add_tiered_retention_policy(p_table_name, p_tier_after, p_drop_after, p_schema_name)`

Two-phase retention: tier to Delta after `p_tier_after`, then delete from Delta after `p_drop_after`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | ChronoTable name |
| `p_tier_after` | INTERVAL | — | Move to Delta after this age |
| `p_drop_after` | INTERVAL | — | Delete from Delta after this age |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — policy_id

```sql
-- Hot: 30 days → Cold: 2 years → Delete
SELECT lakets.add_tiered_retention_policy(
    'sensor_data', '30 days', '730 days'
);
```

### `execute_retention(p_table_name, p_schema_name)`

Runs the retention policy — drops expired chunks. Called by the Databricks Retention job (daily at 3 AM).

**Returns**: `INT` — number of chunks dropped

### `show_retention_policy(p_table_name, p_schema_name)` / `remove_retention_policy(p_table_name, p_schema_name)`

View or remove retention policy for a ChronoTable.

---

## 7. Monitoring & Observability

### `lakets_metrics()`

Returns all LakeTS operational metrics as key-value rows. Compatible with `sql_exporter` for Prometheus scraping.

**Returns**: TABLE with: `metric_name`, `metric_value`, `labels` (JSONB)

Metrics include: total ChronoTables, total chunks by status, rollup refresh lag, policy execution stats, and more.

```sql
-- Scrape all metrics
SELECT * FROM lakets.lakets_metrics();
-- metric_name                | metric_value | labels
-- lakets_chronotables_total  | 5            | {}
-- lakets_chunks_active       | 127          | {}
-- lakets_chunks_tiered       | 340          | {}
-- lakets_rollup_lag_seconds  | 45.2         | {"rollup": "hourly_sensors"}
```

### `chunk_health()`

Per-hypertable chunk health breakdown.

**Returns**: TABLE with: `hypertable`, `total_chunks`, `active_chunks`, `compressed_chunks`, `tiered_chunks`, `dropped_chunks`, `oldest_active`, `newest_active`

### `query_stats(p_limit)`

Top queries by total execution time (wraps `pg_stat_statements`). Gracefully returns empty if the extension is unavailable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_limit` | INT | `20` | Number of top queries to return |

**Returns**: TABLE with: `query`, `calls`, `total_time_ms`, `mean_time_ms`, `rows_returned`

---

## 8. Shadow Sync (Lakehouse Sync)

Works around the Lakebase limitation that partitioned tables cannot participate in Lakehouse Sync CDC. Creates an unpartitioned "shadow" table that mirrors writes via trigger, which Lakehouse Sync can replicate to Delta Lake.

### `enable_sync(p_table_name, p_schema_name)`

Creates the shadow table `_shadow_{table}` and installs a trigger that forwards all INSERT/UPDATE/DELETE operations. Sets `REPLICA IDENTITY FULL` on the shadow for complete CDC capture.

**Returns**: `VOID`

```sql
-- Enable Lakehouse Sync on a partitioned ChronoTable
SELECT lakets.enable_sync('sensor_data');
-- Creates: _shadow_sensor_data (unpartitioned, CDC-enabled)
```

### `disable_sync(p_table_name, p_schema_name)`

Drops the shadow table and removes the trigger.

**Returns**: `VOID`

### `_sync_trigger_fn()`

**Internal trigger function.** Dynamically routes writes from any partition to the correct shadow table using `TG_TABLE_SCHEMA` and `TG_TABLE_NAME`.

---

## 9. Multi-Metric Tables

InfluxDB-style tag + field model for multi-metric time series data.

### `create_metric_table(p_table_name, p_tag_columns, p_field_columns, p_chunk_interval, p_schema_name)`

Creates a ChronoTable optimized for multi-metric data with automatic indexing on tag columns.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Table name |
| `p_tag_columns` | TEXT[] | — | Tag columns (indexed TEXT, low cardinality) |
| `p_field_columns` | TEXT[] | — | Field columns (DOUBLE PRECISION, high cardinality) |
| `p_chunk_interval` | INTERVAL | `'1 day'` | Partition interval |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — chronotable_id

```sql
-- Create a metric table for system monitoring
SELECT lakets.create_metric_table(
    'system_metrics',
    ARRAY['host', 'datacenter', 'service'],     -- tags
    ARRAY['cpu_pct', 'mem_pct', 'disk_io'],     -- fields
    '1 day'
);
```

### `cardinality_stats(p_table_name, p_schema_name)`

Returns distinct value counts per tag column — essential for monitoring series explosion.

**Returns**: TABLE with: `column_name`, `distinct_values`, `total_rows`, `pct_of_rows`

### `cardinality_check(p_table_name, p_max_series, p_schema_name)`

Warns if combined cardinality across all tag columns exceeds a threshold.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Metric table name |
| `p_max_series` | BIGINT | `100000` | Maximum allowed series count |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: TABLE with: `status` (`'OK'` or `'WARNING'`), `combined_cardinality`, `max_allowed`, `tag_columns`

```sql
-- Check if cardinality is under control
SELECT * FROM lakets.cardinality_check('system_metrics');
-- status  | combined_cardinality | max_allowed | tag_columns
-- OK      | 2500                 | 100000      | host,datacenter,service
```

---

## 10. Last Value Cache (LVC)

Sub-10ms access to the latest state of each time series. Uses a trigger-maintained cache table with PRIMARY KEY on the key columns.

### `enable_lvc(p_table_name, p_key_columns, p_value_columns, p_schema_name)`

Creates the cache table `_lvc_{table}` and installs a trigger that upserts on every write.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Source ChronoTable |
| `p_key_columns` | TEXT[] | — | Columns that identify a unique series |
| `p_value_columns` | TEXT[] | — | Columns to cache the latest values of |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
-- Cache latest sensor readings by device
SELECT lakets.enable_lvc(
    'sensor_data',
    ARRAY['device_id'],
    ARRAY['temperature', 'humidity']
);

-- Insert new data — LVC cache is updated automatically
INSERT INTO sensor_data VALUES (now(), 'device-42', 23.5, 65.2);
```

### `latest_values(p_table_name, p_schema_name)`

Reads from the LVC cache table. Sub-10ms response regardless of the source table size.

**Returns**: `SETOF RECORD`

```sql
-- Get latest values for all devices (sub-10ms!)
SELECT * FROM lakets.latest_values('sensor_data')
    AS t(device_id TEXT, temperature DOUBLE PRECISION, humidity DOUBLE PRECISION);
```

### `disable_lvc(p_table_name, p_schema_name)`

Removes the cache table and trigger.

### `lvc_stats()`

Overview of all LVC-enabled tables with cache statistics.

**Returns**: TABLE with: `chronotable`, `cache_table`, `cached_series`, `key_columns`, `value_columns`, `enabled`

---

## 11. Downsampling Pipelines

Multi-resolution data pipelines — automatically route queries to the finest available resolution based on the requested time range.

### `create_downsample_pipeline(p_name, p_source_table, p_intervals, p_retention, p_agg_expressions, p_group_by, p_delta_catalog, p_delta_schema, p_source_schema)`

Registers a multi-resolution pipeline. Metadata-only on Lakebase; execution (Spark jobs that aggregate and write to Delta) happens on Databricks.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Pipeline name |
| `p_source_table` | TEXT | — | Source ChronoTable |
| `p_intervals` | INTERVAL[] | — | Resolutions, finest to coarsest |
| `p_retention` | INTERVAL[] | — | How long to keep each resolution |
| `p_agg_expressions` | TEXT[] | — | Aggregation expressions |
| `p_group_by` | TEXT[] | `NULL` | Group-by columns (tags) |
| `p_delta_catalog` | TEXT | `'main'` | UC catalog for Delta tables |
| `p_delta_schema` | TEXT | `'lakets_rollups'` | UC schema for Delta tables |
| `p_source_schema` | TEXT | `'public'` | Source table schema |

**Returns**: `INT` — pipeline_id

```sql
-- 3-tier resolution: 1m (30d), 1h (1y), 1d (forever)
SELECT lakets.create_downsample_pipeline(
    'sensor_multi_res',
    'sensor_data',
    ARRAY['1 minute', '1 hour', '1 day']::INTERVAL[],
    ARRAY['30 days', '365 days', '3650 days']::INTERVAL[],
    ARRAY['avg(temperature)', 'max(temperature)', 'min(temperature)'],
    ARRAY['device_id']
);
```

### `query_auto_resolution(p_name, p_start, p_end)`

Returns the best Delta table for a given time range — picks the finest resolution whose retention covers the requested range.

**Returns**: TABLE with: `resolution`, `delta_table`, `covers_range`

```sql
-- What resolution covers the last 7 days?
SELECT * FROM lakets.query_auto_resolution('sensor_multi_res', now() - interval '7 days');
-- resolution | delta_table                                    | covers_range
-- 00:01:00   | main.lakets_rollups.sensor_multi_res_1_minute  | true
```

### `show_downsample_pipelines()` / `drop_downsample_pipeline(p_name)`

List or remove downsample pipelines.

---

## 12. Alerting

SQL-native alert rules that evaluate queries and fire when conditions are met.

### `alert_check(p_name, p_query, p_severity)`

Runs a query and returns any "firing" rows as alert events.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Alert rule name |
| `p_query` | TEXT | — | Query that returns rows when alert should fire |
| `p_severity` | TEXT | `'warning'` | Severity: `'info'`, `'warning'`, `'critical'` |

**Returns**: TABLE with: `alert_name`, `severity`, `fired_at`, `alert_data` (JSONB)

```sql
-- Alert when any device has avg temperature > 80°C in the last hour
SELECT * FROM lakets.alert_check(
    'high_temperature',
    $$SELECT device_id, avg(temperature) AS avg_temp
       FROM sensor_data
       WHERE time >= now() - interval '1 hour'
       GROUP BY device_id
       HAVING avg(temperature) > 80$$,
    'critical'
);
```

### `alert_deadman(p_name, p_table_name, p_group_by, p_timeout, p_schema_name)`

Detects **silent series** — groups that haven't reported data within the timeout period. Essential for monitoring data pipeline health.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Alert name |
| `p_table_name` | TEXT | — | ChronoTable to check |
| `p_group_by` | TEXT | — | Column to group by (e.g., `'device_id'`) |
| `p_timeout` | INTERVAL | — | Maximum silence before alerting |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: TABLE with: `alert_name`, `severity`, `fired_at`, `dead_key`, `last_seen`, `silent_for`

```sql
-- Alert if any device hasn't reported in 15 minutes
SELECT * FROM lakets.alert_deadman(
    'device_heartbeat', 'sensor_data', 'device_id', '15 minutes'
);
-- alert_name       | severity | fired_at             | dead_key   | last_seen            | silent_for
-- device_heartbeat | warning  | 2026-04-09 10:30:00  | device-17  | 2026-04-09 10:12:00  | 00:18:00
```

---

## 13. Bulk Ingest

Server-side batch ingest functions for high-throughput data loading.

### `ingest_batch(p_table_name, p_data, p_schema_name)`

Inserts multiple rows from a JSONB array. Designed for edge devices or microservices that batch measurements.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Target ChronoTable |
| `p_data` | JSONB | — | Array of row objects |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — number of rows inserted

```sql
-- Batch insert sensor readings
SELECT lakets.ingest_batch('sensor_data', '[
    {"time": "2026-04-09T10:00:00Z", "device_id": "d1", "temperature": 22.5, "humidity": 60},
    {"time": "2026-04-09T10:00:01Z", "device_id": "d2", "temperature": 23.1, "humidity": 58},
    {"time": "2026-04-09T10:00:02Z", "device_id": "d3", "temperature": 21.8, "humidity": 62}
]');
-- Returns: 3
```

### `ingest_prometheus(p_table_name, p_metric_name, p_labels, p_value, p_timestamp, p_schema_name)`

Inserts a single Prometheus-style metric. Target table must have columns: `time`, `metric_name`, `labels` (JSONB), `value`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Target table |
| `p_metric_name` | TEXT | — | Metric name |
| `p_labels` | JSONB | — | Label key-value pairs |
| `p_value` | DOUBLE PRECISION | — | Metric value |
| `p_timestamp` | TIMESTAMPTZ | `now()` | Observation timestamp |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
-- Prometheus-compatible ingest
SELECT lakets.ingest_prometheus(
    'prom_metrics',
    'http_requests_total',
    '{"method": "GET", "path": "/api/v1/data", "status": "200"}'::JSONB,
    1542.0
);
```

---

## 14. Unity Catalog Integration

Register and tag Delta Lake exports in Databricks Unity Catalog for governance, lineage, and discovery.

### `register_uc_table(p_rollup_name, p_uc_catalog, p_uc_schema)`

Records that a RollUp's Delta export has been registered in Unity Catalog. Called by `uc_registration.py` after the REST API call.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_rollup_name` | TEXT | — | RollUp name |
| `p_uc_catalog` | TEXT | — | UC catalog name |
| `p_uc_schema` | TEXT | — | UC schema name |

**Returns**: `INT` — registry row id

### `tag_uc_table(p_rollup_name, p_tags)`

Persists UC tag metadata. Merges system tags (`lakets.source`, `lakets.version`, `lakets.rollup_name`) with user-provided tags.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_rollup_name` | TEXT | — | RollUp name |
| `p_tags` | JSONB | `'{}'` | User-defined tags |

**Returns**: `JSONB` — merged tag set

```sql
SELECT lakets.tag_uc_table('hourly_sensors', '{"team": "iot", "env": "production"}');
-- Returns: {"team": "iot", "env": "production", "lakets.source": "sensor_data",
--           "lakets.version": "0.1.1", "lakets.rollup_name": "hourly_sensors"}
```

### `get_uc_registrations(p_rollup_name)`

Returns all UC-registered exports (optionally filtered by RollUp name).

**Returns**: TABLE with: `rollup_name`, `uc_catalog`, `uc_schema`, `uc_table`, `full_uc_name`, `delta_table`, `registered_at`, `last_tagged_at`, `tags`

### `unregister_uc_table(p_rollup_name)`

Removes a UC registration record from LakeTS metadata. Does NOT drop the actual UC table.

**Returns**: `BOOLEAN`

---

## 15. Metadata Tables Reference

All metadata lives in the `lakets` schema. These tables are the backbone of LakeTS's state management.

### `_version`
| Column | Type | Description |
|--------|------|-------------|
| `version` | TEXT | Installed semver (e.g., `'0.1.1'`) |
| `installed_at` | TIMESTAMPTZ | Installation timestamp |
| `modules` | TEXT[] | List of installed module names |

Upgrade guard: prevents downgrade or re-install of the same version.

### `_chronotable_registry`
| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique chronotable_id |
| `table_name` | TEXT | Table name |
| `schema_name` | TEXT | Schema name |
| `time_column` | TEXT | Partitioning column |
| `chunk_interval` | INTERVAL | Partition size |
| `created_at` | TIMESTAMPTZ | Registration time |

### `_chunk_metadata`
| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique chunk_id |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `chunk_name` | TEXT | Partition name |
| `range_start` | TIMESTAMPTZ | Lower bound |
| `range_end` | TIMESTAMPTZ | Upper bound |
| `status` | TEXT | `active` / `compressed` / `tiered` / `dropped` |
| `last_modified_at` | TIMESTAMPTZ | Last write timestamp (M23) |
| `created_at` | TIMESTAMPTZ | Creation time |

### `_rollup_registry`
| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique rollup_id |
| `name` | TEXT | RollUp name |
| `query` | TEXT | Aggregation SQL |
| `bucket_interval` | INTERVAL | Bucket size |
| `source_table` | TEXT | Source ChronoTable |
| `refresh_mode` | TEXT | `incremental` / `full` |
| `watermark` | TIMESTAMPTZ | Last refresh boundary |
| `depends_on` | INT[] | Upstream rollup IDs (M25) |
| `bucket_column` | TEXT | Auto-detected bucket column (M27) |
| `export_enabled` | BOOLEAN | Delta export flag (M28) |
| `export_delta_table` | TEXT | Target Delta table path |
| `export_mode` | TEXT | `incremental` / `full` |
| `export_watermark` | TIMESTAMPTZ | Last export boundary |

### `_rollup_invalidation_log`
| Column | Type | Description |
|--------|------|-------------|
| `rollup_id` | INT | FK to `_rollup_registry` |
| `bucket_start` | TIMESTAMPTZ | Dirty bucket timestamp |
| `tier` | TEXT | `hot` / `cold` |
| `invalidated_at` | TIMESTAMPTZ | When marked dirty |

### `_policy_registry`
| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Policy ID |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `policy_type` | TEXT | `compression` / `retention` / `tiered_retention` |
| `config` | JSONB | Policy parameters |
| `enabled` | BOOLEAN | Active flag |
| `last_run_at` | TIMESTAMPTZ | Last execution time |

### `_lvc_registry`
| Column | Type | Description |
|--------|------|-------------|
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `cache_table` | TEXT | Cache table name (`_lvc_{table}`) |
| `key_columns` | TEXT[] | Series identity columns |
| `value_columns` | TEXT[] | Cached value columns |
| `enabled` | BOOLEAN | Active flag |

### `_downsample_registry`
Stores multi-resolution pipeline metadata (intervals, retention, aggregation expressions, Delta targets).

### `_uc_registry`
| Column | Type | Description |
|--------|------|-------------|
| `rollup_name` | TEXT | RollUp name |
| `uc_catalog` | TEXT | Unity Catalog catalog |
| `uc_schema` | TEXT | Unity Catalog schema |
| `uc_table` | TEXT | UC table name |
| `delta_table` | TEXT | Delta Lake path |
| `registered_at` | TIMESTAMPTZ | Registration time |
| `last_tagged_at` | TIMESTAMPTZ | Last tag update |
| `tags` | JSONB | Merged system + user tags |

---

## Databricks Workflow Jobs

These scheduled Databricks jobs drive the operational lifecycle of LakeTS:

| Job | Schedule | What It Calls |
|-----|----------|--------------|
| **Partition Manager** | Every 6h | `_ensure_partitions()` — pre-create future partitions |
| **Compression & Tiering** | Daily 2 AM | `_get_chunks_to_compress()` → Spark JDBC read → Delta write → `compress_chunk()` |
| **Retention** | Daily 3 AM | `execute_retention()` — drops expired chunks in Lakebase and Delta |
| **RollUp Refresh** | Every 15 min | `refresh_rollup_cascade()` — incremental hot-tier refresh |
| **Cold RollUp Refresh** | Daily 1 AM | `refresh_rollup()` with cold-tier dirty buckets |
| **RollUp Export** | Daily 4 AM | Reads export-enabled RollUps → writes to Delta via Spark |

---

## Function Count Summary

| Module | Functions | Aggregates | Triggers | Description |
|--------|-----------|------------|----------|-------------|
| 01_schema | 1 | — | — | Partition parent resolver |
| 02_chronotable | 6 | — | — | Time-partitioned table management |
| 03_timeseries | 7 | 2 | — | Analytics: bucket, first/last, gapfill, locf, interpolate, delta, rate, histogram |
| 04_rollup | 11 | — | 1 | Incremental aggregation engine |
| 05_compression | 6 | — | — | Tiering policies (Lakebase → Delta) |
| 06_retention | 5 | — | — | Data lifecycle management |
| 07_monitoring | 3 | — | — | Prometheus-compatible metrics |
| 08_metric_table | 3 | — | — | InfluxDB-style tag+field model |
| 09_lvc | 5 | — | 1 | Sub-10ms latest-state cache |
| 10_downsample | 4 | — | — | Multi-resolution pipelines |
| 11_alerts | 2 | — | — | SQL-native alert rules |
| 12_ingest | 2 | — | — | Batch JSON + Prometheus ingest |
| 13_shadow_sync | 3 | — | 1 | Lakehouse Sync workaround |
| 14_rollup_opt | 15 | — | 3 | M23–M28 optimization modules |
| 15_uc_integration | 4 | — | — | Unity Catalog registration |
| **Total** | **77** | **2** | **6** | |

---

*LakeTS v0.1.1 — Pure SQL Time Series for Databricks Lakebase*
*All objects in the `lakets` schema. PostgreSQL 16+ required. No extensions.*
