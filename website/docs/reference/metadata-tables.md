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
| `table_name` | TEXT | Table name |
| `schema_name` | TEXT | Schema name |
| `time_column` | TEXT | Partitioning column |
| `chunk_interval` | INTERVAL | Partition size |
| `created_at` | TIMESTAMPTZ | Registration time |

## `_chunk_metadata`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique chunk_id |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `chunk_name` | TEXT | Partition name |
| `range_start` | TIMESTAMPTZ | Lower bound |
| `range_end` | TIMESTAMPTZ | Upper bound |
| `status` | TEXT | `active` / `compressed` / `tiered` / `dropped` |
| `last_modified_at` | TIMESTAMPTZ | Last write timestamp (powers chunk-skip pruning) |
| `created_at` | TIMESTAMPTZ | Creation time |

## `_rollup_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Unique rollup_id |
| `name` | TEXT | RollUp name |
| `query` | TEXT | Aggregation SQL |
| `bucket_interval` | INTERVAL | Bucket size |
| `source_table` | TEXT | Source ChronoTable |
| `refresh_mode` | TEXT | `incremental` / `full` |
| `watermark` | TIMESTAMPTZ | Last refresh boundary |
| `depends_on` | INT[] | Upstream rollup IDs for cascade refresh |
| `bucket_column` | TEXT | Auto-detected bucket column |

## `_rollup_invalidation_log`

| Column | Type | Description |
|--------|------|-------------|
| `rollup_id` | INT | FK to `_rollup_registry` |
| `bucket_start` | TIMESTAMPTZ | Dirty bucket timestamp |
| `tier` | TEXT | `hot` / `cold` |
| `invalidated_at` | TIMESTAMPTZ | When marked dirty |

## `_policy_registry`

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Policy ID |
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `policy_type` | TEXT | `compression` / `retention` / `tiered_retention` |
| `config` | JSONB | Policy parameters |
| `enabled` | BOOLEAN | Active flag |
| `last_run_at` | TIMESTAMPTZ | Last execution time |

## `_lvc_registry`

| Column | Type | Description |
|--------|------|-------------|
| `chronotable_id` | INT | FK to `_chronotable_registry` |
| `cache_table` | TEXT | Cache table name (`_lvc_{table}`) |
| `key_columns` | TEXT[] | Series-identity columns |
| `value_columns` | TEXT[] | Cached value columns |
| `enabled` | BOOLEAN | Active flag |

## `_downsample_registry`

Stores multi-resolution pipeline metadata — intervals, retention, aggregation expressions, UC table targets.


