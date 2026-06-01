---
title: Metadata tables
sidebar_label: Metadata tables
sidebar_position: 13
description: The metadata tables that back LakeTS — every registry the engine reads from.
---

# Metadata tables

Every LakeTS metadata object lives in the `lakets` schema. These tables are the backbone of state management.

## `_version`

| Column | Type | Description |
|--------|------|-------------|
| `version` | TEXT | Installed semver (e.g. `'0.1.2'`) |
| `installed_at` | TIMESTAMPTZ | Installation timestamp |
| `modules` | TEXT[] | List of installed module names |

Upgrade guard: prevents downgrade or re-install of the same version.

## `_chronotable_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique chronotable_id |
| `schema_name` | TEXT | Schema name |
| `table_name` | TEXT | Table name |
| `time_column` | TEXT | Partitioning column |
| `chunk_interval` | INTERVAL | Partition size (default `7 days`) |
| `space_column` | TEXT | Optional secondary (hash) partition column |
| `space_partitions` | INT | Number of space partitions (default `1`) |
| `tiering_enabled` | BOOLEAN | Whether a tiering policy is active |
| `retention_interval` | INTERVAL | Retention window, if a policy is set |
| `shadow_table_name` | TEXT | `lakets_cdf` shadow table name when sync is enabled |
| `sync_enabled` | BOOLEAN | Whether Lakebase CDF sync is enabled |
| `last_synced_lsn` | BIGINT | Last LSN mirrored to the shadow table |
| `created_at` | TIMESTAMPTZ | Registration time |

## `_chunk_metadata`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique chunk_id |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `chunk_name` | TEXT | Partition name |
| `range_start` | TIMESTAMPTZ | Lower bound |
| `range_end` | TIMESTAMPTZ | Upper bound |
| `status` | TEXT | `active` / `tiered` / `dropped` |
| `row_count` | BIGINT | Estimated rows in the chunk |
| `size_bytes` | BIGINT | Estimated chunk size on disk |
| `tiered_at` | TIMESTAMPTZ | When the chunk was tiered (partition dropped) |
| `last_write_lsn` | PG_LSN | WAL position of the chunk's most recent write (used by the tiering durability gate) |
| `last_modified_at` | TIMESTAMPTZ | Last write timestamp (powers chunk-skip pruning) |
| `created_at` | TIMESTAMPTZ | Creation time |

## `_rollup_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique rollup_id |
| `name` | TEXT | RollUp name (unique) |
| `source_chronotable_id` | INT | FK to `_chronotable_registry` (the source ChronoTable) |
| `rollup_table` | TEXT | Materialized RollUp table name (`_rollup_{name}` in `public`) |
| `realtime_view` | TEXT | Real-time view name, if created |
| `bucket_interval` | INTERVAL | Bucket size |
| `refresh_lag` | INTERVAL | Minimum time between refreshes (default `1 hour`) |
| `watermark` | TIMESTAMPTZ | Last refresh boundary |
| `query_text` | TEXT | Aggregation SQL |
| `last_refreshed_at` | TIMESTAMPTZ | Timestamp of the last successful refresh |
| `bucket_column` | TEXT | Auto-detected bucket column (default `bucket`) |
| `source_time_column` | TEXT | Source time column used for predicate injection |
| `predicate_injection` | BOOLEAN | Whether incremental refresh injects a time predicate |
| `depends_on` | INT[] | Upstream rollup IDs for cascade refresh |
| `cold_query_text` | TEXT | Optional cold-tier (Delta) re-aggregation query |
| `sync_enabled` | BOOLEAN | Whether Lakebase CDF sync is enabled |
| `shadow_table_name` | TEXT | `lakets_cdf` shadow table name when sync is enabled |
| `created_at` | TIMESTAMPTZ | Registration time |

## `_rollup_invalidation_log`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique entry id |
| `rollup_id` | INT | FK to `_rollup_registry` |
| `bucket_start` | TIMESTAMPTZ | Dirty bucket timestamp |
| `tier` | TEXT | `hot` / `cold` |
| `invalidated_at` | TIMESTAMPTZ | When marked dirty |

## `_policy_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Policy ID |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `policy_type` | TEXT | `tiering` / `retention` / `tiered_retention` |
| `config` | JSONB | Policy parameters |
| `enabled` | BOOLEAN | Active flag |
| `last_run_at` | TIMESTAMPTZ | Last execution time |
| `created_at` | TIMESTAMPTZ | Registration time |

## `_lvc_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique LVC id |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `cache_table_name` | TEXT | Cache table name (`_lvc_{table}`) |
| `key_columns` | TEXT[] | Series-identity columns |
| `value_columns` | TEXT[] | Cached value columns |
| `enabled` | BOOLEAN | Active flag |
| `created_at` | TIMESTAMPTZ | Registration time |

## `_downsample_registry`

Stores multi-resolution downsampling pipeline metadata, executed by the Databricks downsampling job.

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique pipeline id |
| `name` | TEXT | Pipeline name (unique) |
| `source_table` | TEXT | Source table name |
| `source_schema` | TEXT | Source schema (default `public`) |
| `intervals` | INTERVAL[] | Resolution intervals (e.g. `1m`, `1h`, `1d`) |
| `retention` | INTERVAL[] | Per-resolution retention windows |
| `agg_expressions` | TEXT[] | Aggregation expressions applied at each resolution |
| `group_by` | TEXT[] | Optional grouping (tag) columns |
| `delta_catalog` | TEXT | Target Unity Catalog catalog (default `main`) |
| `delta_schema` | TEXT | Target Delta schema (default `lakets_rollups`) |
| `created_at` | TIMESTAMPTZ | Registration time |


