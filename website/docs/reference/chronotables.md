---
title: ChronoTables
sidebar_label: ChronoTables
sidebar_position: 1
description: Functions for creating, listing, and managing time-partitioned ChronoTables.
---

# ChronoTables

ChronoTables are LakeTS's core abstraction — regular PostgreSQL tables converted into RANGE-partitioned time-series tables. Each partition (chunk) covers a fixed time interval and is tracked in `_chronotable_registry` and `_chunk_metadata`.

**Why RANGE partitioning?** Native partition pruning on time predicates, instant `DROP PARTITION` for retention, and automatic insert routing without application logic.

## `create_chronotable(p_table_name, p_time_column, p_chunk_interval, p_schema_name)`

Converts a regular table into a time-partitioned ChronoTable. The primary entry point for onboarding any time-series table.

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

## `create_hypertable(p_table_name, p_time_column, p_chunk_interval, p_schema_name, p_if_not_exists)`

The original v1 name for ChronoTable creation. Identical behavior to `create_chronotable` with an additional `p_if_not_exists` parameter.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Table to convert |
| `p_time_column` | TEXT | — | Time column (TIMESTAMPTZ) |
| `p_chunk_interval` | INTERVAL | `'7 days'` | Partition interval |
| `p_schema_name` | TEXT | `'public'` | Schema |
| `p_if_not_exists` | BOOLEAN | `FALSE` | Skip if already a ChronoTable |

**Returns**: `INT` — chronotable_id

## `set_chunk_interval(p_table_name, p_chunk_interval, p_schema_name)`

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

## `show_chunks(p_table_name, p_older_than, p_newer_than, p_schema_name)`

Lists all partitions for a ChronoTable with metadata.

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

## `drop_chunks(p_table_name, p_older_than, p_schema_name)`

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

## Internal helpers

### `_ensure_partitions(p_chronotable_id, p_past_count, p_future_count, p_range_start, p_range_end)`

Pre-creates partitions for a ChronoTable. Called automatically by `create_chronotable` and by the Databricks Partition Manager job (every 6 hours).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_chronotable_id` | INT | — | ChronoTable registry ID |
| `p_past_count` | INT | `1` | Number of past partitions to ensure |
| `p_future_count` | INT | `3` | Number of future partitions to ensure |
| `p_range_start` | TIMESTAMPTZ | `NULL` | Explicit range start (overrides counts) |
| `p_range_end` | TIMESTAMPTZ | `NULL` | Explicit range end (overrides counts) |

**Returns**: `INT` — number of new partitions created. Idempotent — skips existing partitions.

### `_resolve_partition_parent(p_schema, p_table)`

Resolves a partition's parent table name from the PostgreSQL inheritance catalog. Used by triggers that fire on individual partitions.

**Returns**: `TEXT` — parent table name
