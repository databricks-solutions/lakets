---
title: API Reference
sidebar_label: API Reference
sidebar_position: 1
description: Public LakeTS function signatures organized by area — ChronoTables, RollUps, LVC, ingest, alerts, monitoring.
---

# LakeTS API Reference

All functions live in the `lakets` schema. Internal functions prefixed with `_` are not part of the public API.

## ChronoTable Management

### `lakets.create_chronotable` (alias: `create_hypertable`)
Converts a regular table to a time-partitioned ChronoTable.

```sql
lakets.create_chronotable(
    p_table_name    TEXT,
    p_time_column   TEXT,
    p_chunk_interval INTERVAL DEFAULT '7 days',
    p_schema_name   TEXT DEFAULT 'public',
    p_if_not_exists BOOLEAN DEFAULT FALSE
) RETURNS INT  -- ChronoTable ID
```

> `create_hypertable()` is kept as a backward-compatible alias.

**Behavior**: Renames the original table, creates a partitioned table with the same schema, copies data, creates partitions covering the data range + future, adds a time index, and registers in metadata.

### `lakets.set_chunk_interval`
Changes the chunk interval for future partitions.

```sql
lakets.set_chunk_interval(
    p_table_name    TEXT,
    p_chunk_interval INTERVAL,
    p_schema_name   TEXT DEFAULT 'public'
) RETURNS VOID
```

### `lakets.show_chunks`
Lists partitions with metadata.

```sql
lakets.show_chunks(
    p_table_name TEXT,
    p_older_than INTERVAL DEFAULT NULL,
    p_newer_than INTERVAL DEFAULT NULL,
    p_schema_name TEXT DEFAULT 'public'
) RETURNS TABLE (chunk_name TEXT, range_start TIMESTAMPTZ, range_end TIMESTAMPTZ,
                 status TEXT, row_count BIGINT, size_bytes BIGINT, created_at TIMESTAMPTZ)
```

### `lakets.drop_chunks`
Drops partitions older than a given interval.

```sql
lakets.drop_chunks(
    p_table_name TEXT,
    p_older_than INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
) RETURNS INT  -- number of chunks dropped
```

---

## Time Series Functions

### `lakets.time_bucket`
Truncates a timestamp to the nearest bucket boundary.

```sql
lakets.time_bucket(
    p_interval  INTERVAL,
    p_timestamp TIMESTAMPTZ,
    p_origin    TIMESTAMPTZ DEFAULT '2000-01-01'::timestamptz
) RETURNS TIMESTAMPTZ
```

Supports sub-month intervals (delegates to `date_bin`) and month/year intervals (custom logic).

### `lakets.time_bucket_gapfill`
Generates a continuous series of time buckets.

```sql
lakets.time_bucket_gapfill(
    p_interval INTERVAL,
    p_start    TIMESTAMPTZ,
    p_finish   TIMESTAMPTZ
) RETURNS SETOF TIMESTAMPTZ
```

Use with `LEFT JOIN` to fill gaps in sparse data.

### `lakets.first` (aggregate)
Returns the value associated with the earliest timestamp.

```sql
lakets.first(value DOUBLE PRECISION, ts TIMESTAMPTZ) RETURNS DOUBLE PRECISION
```

### `lakets.last` (aggregate)
Returns the value associated with the latest timestamp.

```sql
lakets.last(value DOUBLE PRECISION, ts TIMESTAMPTZ) RETURNS DOUBLE PRECISION
```

### `lakets.locf`
Last Observation Carried Forward. Returns the value if non-NULL, otherwise the previous value.

```sql
lakets.locf(p_value DOUBLE PRECISION, p_prev_value DOUBLE PRECISION DEFAULT NULL)
RETURNS DOUBLE PRECISION
```

Use with `LAG()` window function: `lakets.locf(val, LAG(val) OVER (ORDER BY time))`

### `lakets.interpolate`
Linear interpolation between two known values.

```sql
lakets.interpolate(
    p_value      DOUBLE PRECISION,  -- current (possibly NULL)
    p_prev_value DOUBLE PRECISION,  -- previous known value
    p_next_value DOUBLE PRECISION,  -- next known value
    p_prev_time  TIMESTAMPTZ,
    p_curr_time  TIMESTAMPTZ,
    p_next_time  TIMESTAMPTZ
) RETURNS DOUBLE PRECISION
```

### `lakets.delta`
Difference between consecutive values with optional counter reset handling.

```sql
lakets.delta(
    p_value         DOUBLE PRECISION,
    p_prev_value    DOUBLE PRECISION,
    p_handle_resets BOOLEAN DEFAULT TRUE
) RETURNS DOUBLE PRECISION
```

When `handle_resets=TRUE` and value < prev_value (counter reset), returns the value itself.

### `lakets.rate`
Rate of change per second.

```sql
lakets.rate(
    p_value         DOUBLE PRECISION,
    p_prev_value    DOUBLE PRECISION,
    p_time          TIMESTAMPTZ,
    p_prev_time     TIMESTAMPTZ,
    p_handle_resets BOOLEAN DEFAULT TRUE
) RETURNS DOUBLE PRECISION
```

### `lakets.histogram`
Returns the bucket index for a value in a range.

```sql
lakets.histogram(
    p_value       DOUBLE PRECISION,
    p_min         DOUBLE PRECISION,
    p_max         DOUBLE PRECISION,
    p_num_buckets INT
) RETURNS INT  -- 0-based bucket index
```

---

## RollUp Engine (Incremental Aggregates)

> Replaces the original Continuous Aggregates (Module 3). The design rationale is documented in the internal PRD `PRD_LakeTS_Incremental_Refresh.md`.

### `lakets.create_rollup`
Creates a RollUp Table with initial full load and unique index.

```sql
lakets.create_rollup(
    p_name            TEXT,
    p_query           TEXT,     -- SELECT with GROUP BY (bucket column auto-detected)
    p_bucket_interval INTERVAL DEFAULT '1 hour',
    p_source_table    TEXT DEFAULT NULL,
    p_source_schema   TEXT DEFAULT 'public',
    p_refresh_mode    TEXT DEFAULT 'incremental',  -- 'incremental' or 'full'
    p_depends_on      TEXT[] DEFAULT '{}'           -- names of prerequisite RollUps (M25)
) RETURNS INT  -- RollUp ID
```

Creates `_rollup_<name>` table in `public` schema. Auto-detects the bucket column via `_detect_bucket_column()` (M27). Builds unique index on all columns. Resolves `p_depends_on` names to IDs for DAG orchestration. Registers with watermark = `max(bucket)`.

### `lakets.refresh_rollup`
Incremental or full refresh. Returns TRUE if refreshed, FALSE if skipped due to `refresh_lag`.

```sql
lakets.refresh_rollup(p_name TEXT) RETURNS BOOLEAN
```

**Incremental mode**: DELETE+INSERT only for buckets from `watermark - bucket_interval` forward, plus any hot-tier invalidation log entries.
**Full mode**: TRUNCATE + INSERT entire query.

### `lakets.create_rollup_view`
Creates a real-time UNION view using `_rollup_watermark()` as the boundary.

```sql
lakets.create_rollup_view(p_name TEXT, p_raw_query TEXT) RETURNS VOID
```

Creates `_rollup_rt_<name>` view. The `p_raw_query` should use `lakets._rollup_watermark('<name>')` as the time boundary for fresh data.

### `lakets.drop_rollup`
Drops the RollUp view, RollUp Table, and registry entry.

```sql
lakets.drop_rollup(p_name TEXT) RETURNS VOID
```

### `lakets.show_rollups`
Lists all RollUps with status.

```sql
lakets.show_rollups() RETURNS TABLE (
    name TEXT, rollup_table TEXT, realtime_view TEXT,
    bucket_interval INTERVAL, refresh_mode TEXT, refresh_lag INTERVAL,
    watermark TIMESTAMPTZ, last_refreshed_at TIMESTAMPTZ, source_table TEXT,
    bucket_column TEXT, depends_on INT[], export_enabled BOOLEAN
)
```

### `lakets._rollup_watermark`
Returns the stored watermark for a RollUp. Declared `STABLE` for query plan caching.

```sql
lakets._rollup_watermark(p_name TEXT) RETURNS TIMESTAMPTZ
```

### `lakets.enable_rollup_invalidation`
Installs invalidation triggers on the source ChronoTable for mutation tracking (opt-in).

```sql
lakets.enable_rollup_invalidation(p_rollup_name TEXT) RETURNS VOID
```

Installs two triggers per source table:
- **Per-row** (`AFTER UPDATE OR DELETE`): Tracks individual mutations via `_rollup_invalidation_trigger_fn()`
- **Statement-level** (`AFTER INSERT REFERENCING NEW TABLE`): Catches bulk imports (COPY FROM, multi-row INSERT) via `_bulk_import_invalidation()` (M27)

One trigger pair per source table handles all RollUps. Idempotent.

### `lakets.disable_rollup_invalidation`
Removes the invalidation trigger (if no other RollUps need it) and clears log entries.

```sql
lakets.disable_rollup_invalidation(p_rollup_name TEXT) RETURNS VOID
```

### `lakets.invalidate_rollup_range`
Manually marks time buckets as dirty for re-aggregation.

```sql
lakets.invalidate_rollup_range(
    p_name TEXT,
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ,
    p_tier TEXT DEFAULT NULL  -- NULL = auto-detect from chunk metadata (M26)
) RETURNS INT  -- number of buckets invalidated
```

When `p_tier` is `NULL` (default), automatically resolves hot/cold tier by checking `_chunk_metadata.status` for each bucket via `_resolve_bucket_tier()` (M26). Use after bulk `COPY` imports or after correcting cold-tier data in Delta Lake.

---

## RollUp Optimization (Modules 23–28)

### `lakets.refresh_rollup_cascade`
Refreshes all RollUps in dependency order (topological sort). If `p_name` is provided, refreshes that RollUp and all its transitive dependencies. If `NULL`, refreshes all RollUps.

```sql
lakets.refresh_rollup_cascade(
    p_name TEXT DEFAULT NULL
) RETURNS TABLE (rollup_name TEXT, refreshed BOOLEAN, refresh_ms FLOAT)
```

### `lakets.show_rollup_dag`
Human-readable DAG visualization showing refresh order and dependencies.

```sql
lakets.show_rollup_dag() RETURNS TABLE (
    rollup_name TEXT, depends_on_names TEXT[], refresh_order INT,
    bucket_interval INTERVAL, last_refreshed TIMESTAMPTZ
)
```

### `lakets.enable_rollup_export`
Enables periodic export of RollUp Table rows to Delta Lake.

```sql
lakets.enable_rollup_export(
    p_rollup_name TEXT,
    p_delta_table TEXT,         -- e.g., 'main.lakets_rollups.metrics_hourly'
    p_export_mode TEXT DEFAULT 'incremental'  -- 'full' or 'incremental'
) RETURNS VOID
```

### `lakets.disable_rollup_export`
Disables RollUp export.

```sql
lakets.disable_rollup_export(p_rollup_name TEXT) RETURNS VOID
```

### `lakets.show_rollup_exports`
Shows export status and lag for all export-enabled RollUps.

```sql
lakets.show_rollup_exports() RETURNS TABLE (
    rollup_name TEXT, delta_table TEXT, export_mode TEXT,
    last_exported_at TIMESTAMPTZ, watermark TIMESTAMPTZ, export_lag INTERVAL
)
```

---

## Compression & Tiering

### `lakets.add_compression_policy`
Registers a policy for automatic tiering to Delta Lake.

```sql
lakets.add_compression_policy(
    p_table_name    TEXT,
    p_compress_after INTERVAL,
    p_segment_by    TEXT DEFAULT NULL,
    p_order_by      TEXT DEFAULT NULL,
    p_schema_name   TEXT DEFAULT 'public'
) RETURNS INT  -- policy ID
```

### `lakets.compress_chunk` / `lakets.decompress_chunk`
Manually mark a chunk as compressed or restore it.

```sql
lakets.compress_chunk(p_chunk_name TEXT) RETURNS VOID
lakets.decompress_chunk(p_chunk_name TEXT) RETURNS VOID
```

### `lakets.show_compression_policy` / `lakets.remove_compression_policy`
View or remove the compression policy.

---

## Retention

### `lakets.add_retention_policy`
Auto-drops chunks older than the interval.

```sql
lakets.add_retention_policy(p_table_name TEXT, p_drop_after INTERVAL, ...) RETURNS INT
```

### `lakets.add_tiered_retention_policy`
Tiers data after `tier_after`, drops after `drop_after`.

```sql
lakets.add_tiered_retention_policy(
    p_table_name TEXT, p_tier_after INTERVAL, p_drop_after INTERVAL, ...
) RETURNS INT
```

### `lakets.execute_retention`
Runs the retention policy immediately.

```sql
lakets.execute_retention(p_table_name TEXT, ...) RETURNS INT  -- chunks dropped
```

### `lakets.show_retention_policy` / `lakets.remove_retention_policy`
View or remove retention policies.

---

## Monitoring

### `lakets.lakets_metrics`
Returns all operational metrics as Prometheus-compatible rows.

```sql
lakets.lakets_metrics() RETURNS TABLE (metric_name TEXT, metric_value FLOAT8, labels JSONB)
```

### `lakets.chunk_health`
Per-ChronoTable chunk health report.

```sql
lakets.chunk_health() RETURNS TABLE (chronotable TEXT, total_chunks BIGINT, ...)
```

### `lakets.query_stats`
Top queries from pg_stat_statements filtered for LakeTS usage.

```sql
lakets.query_stats(p_limit INT DEFAULT 20) RETURNS TABLE (...)
```

---

## Shadow Sync (Lakehouse Sync)

### `lakets.enable_sync`
Creates a shadow table + trigger for Lakehouse Sync CDC.

```sql
lakets.enable_sync(p_table_name TEXT, p_schema_name TEXT DEFAULT 'public') RETURNS VOID
```

### `lakets.disable_sync`
Removes the shadow table and trigger.

```sql
lakets.disable_sync(p_table_name TEXT, p_schema_name TEXT DEFAULT 'public') RETURNS VOID
```

---

## Multi-Metric ChronoTables (V2)

### `lakets.create_metric_table`
Creates a ChronoTable optimized for multi-metric data with indexed tags.

```sql
lakets.create_metric_table(
    p_table_name    TEXT,
    p_tag_columns   TEXT[],      -- indexed TEXT columns (dimensions)
    p_field_columns TEXT[],      -- DOUBLE PRECISION columns (values)
    p_chunk_interval INTERVAL DEFAULT '1 day',
    p_schema_name   TEXT DEFAULT 'public'
) RETURNS INT  -- ChronoTable ID
```

Creates: table + ChronoTable partitioning + composite index on `(tags..., time DESC)` + BRIN index on time.

### `lakets.cardinality_stats`
Returns distinct value counts per tag (TEXT) column.

```sql
lakets.cardinality_stats(p_table_name TEXT, p_schema_name TEXT DEFAULT 'public')
RETURNS TABLE (column_name TEXT, distinct_values BIGINT, total_rows BIGINT, pct_of_rows NUMERIC)
```

### `lakets.cardinality_check`
Checks if combined series cardinality exceeds a threshold.

```sql
lakets.cardinality_check(
    p_table_name TEXT, p_max_series BIGINT DEFAULT 100000, p_schema_name TEXT DEFAULT 'public'
) RETURNS TABLE (status TEXT, combined_cardinality BIGINT, max_allowed BIGINT, tag_columns TEXT)
```

Returns `OK`, `WARNING` (>80% of max), or `CRITICAL` (>100% of max).

---

## Last Value Cache (V2)

### `lakets.enable_lvc`
Creates a trigger-maintained cache table for sub-10ms latest-state queries.

```sql
lakets.enable_lvc(
    p_table_name   TEXT,
    p_key_columns  TEXT[],     -- columns that identify a series (e.g., ['host'])
    p_value_columns TEXT[],    -- columns to cache (e.g., ['cpu', 'memory'])
    p_schema_name  TEXT DEFAULT 'public'
) RETURNS VOID
```

Creates `_lvc_<table>` with key columns as PRIMARY KEY. Every INSERT triggers an UPSERT into the cache.

### `lakets.disable_lvc`
Removes the cache table and trigger.

```sql
lakets.disable_lvc(p_table_name TEXT, p_schema_name TEXT DEFAULT 'public') RETURNS VOID
```

### `lakets.latest_values`
Reads from the LVC cache table. Returns SETOF RECORD.

```sql
-- Query: SELECT * FROM _lvc_<table> ORDER BY last_updated DESC
lakets.latest_values(p_table_name TEXT, p_schema_name TEXT DEFAULT 'public') RETURNS SETOF RECORD
```

### `lakets.lvc_stats`
Cache statistics across all LVC-enabled tables.

```sql
lakets.lvc_stats() RETURNS TABLE (
    chronotable TEXT, cache_table TEXT, cached_series BIGINT,
    key_columns TEXT, value_columns TEXT, enabled BOOLEAN
)
```

---

## Downsampling Pipeline Registry (V2)

### `lakets.create_downsample_pipeline`
Registers a multi-resolution rollup pipeline. Execution is on Databricks.

```sql
lakets.create_downsample_pipeline(
    p_name TEXT, p_source_table TEXT,
    p_intervals INTERVAL[],        -- e.g., ['1 minute', '1 hour', '1 day']
    p_retention INTERVAL[],        -- e.g., ['30 days', '1 year', 'forever']
    p_agg_expressions TEXT[],      -- e.g., ['avg(cpu)', 'max(memory)']
    p_group_by TEXT[] DEFAULT NULL,
    p_delta_catalog TEXT DEFAULT 'main',
    p_delta_schema TEXT DEFAULT 'lakets_rollups',
    p_source_schema TEXT DEFAULT 'public'
) RETURNS INT
```

### `lakets.query_auto_resolution`
Returns the best Delta table for a given time range.

```sql
lakets.query_auto_resolution(p_name TEXT, p_start TIMESTAMPTZ, p_end TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (resolution INTERVAL, delta_table TEXT, covers_range BOOLEAN)
```

### `lakets.show_downsample_pipelines` / `lakets.drop_downsample_pipeline`
List or remove registered pipelines.

---

## Alert Rules (V2)

### `lakets.alert_check`
Runs a query and returns rows that match alert conditions.

```sql
lakets.alert_check(p_name TEXT, p_query TEXT, p_severity TEXT DEFAULT 'warning')
RETURNS TABLE (alert_name TEXT, severity TEXT, fired_at TIMESTAMPTZ, alert_data JSONB)
```

The query should return rows that are "firing" (e.g., `HAVING max(cpu) > 90`).

### `lakets.alert_deadman`
Detects series that haven't reported data within a timeout.

```sql
lakets.alert_deadman(
    p_name TEXT, p_table_name TEXT, p_group_by TEXT,
    p_timeout INTERVAL, p_schema_name TEXT DEFAULT 'public'
) RETURNS TABLE (alert_name TEXT, severity TEXT, fired_at TIMESTAMPTZ,
                 dead_key TEXT, last_seen TIMESTAMPTZ, silent_for INTERVAL)
```

---

## Bulk Ingest (V2)

### `lakets.ingest_batch`
Inserts multiple rows from a JSONB array.

```sql
lakets.ingest_batch(p_table_name TEXT, p_data JSONB, p_schema_name TEXT DEFAULT 'public')
RETURNS INT  -- rows inserted
```

### `lakets.ingest_prometheus`
Inserts a single Prometheus-style metric. Target table must have `time`, `metric_name`, `labels` (JSONB), `value` columns.

```sql
lakets.ingest_prometheus(
    p_table_name TEXT, p_metric_name TEXT, p_labels JSONB,
    p_value DOUBLE PRECISION, p_timestamp TIMESTAMPTZ DEFAULT now(),
    p_schema_name TEXT DEFAULT 'public'
) RETURNS VOID
```
