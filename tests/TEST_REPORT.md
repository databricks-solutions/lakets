# LakeTS Test Report

**Date:** 2026-03-26
**Environment:** Lakebase provisioned instance (PG 16.12, CU_1)
**Branch:** `feat/rollup-optimization-m23-m28`

---

## Summary

| Metric | Value |
|--------|-------|
| **Test Suites** | 15 (13 SQL + 1 SQL hardening + 1 Python) |
| **Total Test Cases** | 146 |
| **Passed** | 146 |
| **Failed** | 0 |
| **Skipped** | 0 |
| **Pass Rate** | **100%** |

---

## Results by Test Suite

| # | Test Suite | Module(s) | Tests | Passed | Status |
|---|-----------|-----------|-------|--------|--------|
| 1 | test_chronotable | 01_chronotable | 8 | 8 | PASS |
| 2 | test_timeseries_functions | 02_timeseries_functions | 20 | 20 | PASS |
| 3 | test_rollup | 03_rollup | 12 | 12 | PASS |
| 4 | test_compression | 04_compression | 6 | 6 | PASS |
| 5 | test_retention | 05_retention | 6 | 6 | PASS |
| 6 | test_monitoring | 06_monitoring | 7 | 7 | PASS |
| 7 | test_shadow_sync | 07_shadow_sync | 5 | 5 | PASS |
| 8 | test_metric_table | 08_metric_table | 7 | 7 | PASS |
| 9 | test_lvc | 09_lvc | 5 | 5 | PASS |
| 10 | test_downsample | 10_downsample | 6 | 6 | PASS |
| 11 | test_alerts | 11_alerts | 4 | 4 | PASS |
| 12 | test_ingest | 12_ingest | 7 | 7 | PASS |
| 13 | test_rollup_optimization | 13_rollup_optimization | 25 | 25 | PASS |
| 14 | test_security_hardening | Schema, indexes, constraints | 13 | 13 | PASS |
| 15 | test_python_patterns | Python workflow patterns | 15 | 15 | PASS |

---

## Detailed Test Cases

### 1. test_chronotable (8 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | create_chronotable returns valid id | PASS |
| T2 | Data preserved after creation (72 rows) | PASS |
| T3 | Correct number of partitions created (7 chunks) | PASS |
| T4 | Underlying table is partitioned (relkind=p) | PASS |
| T5 | drop_chunks removes old partitions | PASS |
| T6 | alter_chunk_interval changes interval | PASS |
| T7 | Backward compatibility: if_not_exists | PASS |
| T8 | _chronotable_registry view works | PASS |

### 2. test_timeseries_functions (20 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | time_bucket 15-minute intervals | PASS |
| T2 | time_bucket 1-hour intervals | PASS |
| T3 | time_bucket monthly intervals | PASS |
| T4 | time_bucket quarterly intervals | PASS |
| T5 | first() and last() aggregates | PASS |
| T6 | gapfill returns correct bucket count | PASS |
| T7 | locf (last observation carried forward) | PASS |
| T8 | interpolate midpoint calculation | PASS |
| T9 | delta (difference between values) | PASS |
| T10 | rate (per-second change) | PASS |
| T11 | histogram (value distribution) | PASS |
| T12 | Year boundary monthly bucketing | PASS |
| T13 | Custom origin time_bucket | PASS |
| T14 | interpolate returns NULL for missing bound | PASS |
| T15 | interpolate same timestamps returns prev_value | PASS |
| T16 | rate returns NULL for equal timestamps | PASS |
| T17 | rate returns NULL for NULL prev | PASS |
| T18 | histogram boundary conditions (min, max, below-min) | PASS |
| T19 | first/last with single row | PASS |
| T20 | gapfill with single bucket | PASS |

### 3. test_rollup (12 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | create_rollup returns valid ID | PASS |
| T2 | RollUp table populated (168 rows) | PASS |
| T3 | show_rollups lists rollup with watermark | PASS |
| T4 | refresh_rollup advances watermark | PASS |
| T5 | refresh_rollup respects refresh_lag | PASS |
| T6 | Real-time view combines materialized + hot data | PASS |
| T7 | _rollup_watermark returns correct value | PASS |
| T8 | Invalidation log captures hot-tier entries | PASS |
| T9 | Invalidation log cleared after refresh | PASS |
| T10 | invalidate_rollup_range creates cold-tier entries | PASS |
| T11 | Trigger removed and invalidation log cleared | PASS |
| T12 | drop_rollup removes all objects | PASS |

### 4. test_compression (6 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | add_compression_policy returns policy ID | PASS |
| T2 | show_compression_policy returns correct interval | PASS |
| T3 | _get_chunks_to_compress finds eligible chunks | PASS |
| T4 | compress_chunk sets status to compressed | PASS |
| T5 | decompress_chunk restores active status | PASS |
| T6 | remove_compression_policy disables compression | PASS |

### 5. test_retention (6 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | add_retention_policy returns policy ID | PASS |
| T2 | show_retention_policy returns correct interval | PASS |
| T3 | apply_retention drops old chunks | PASS |
| T4 | Tiered retention policy creation | PASS |
| T5 | tier_after >= drop_after rejected | PASS |
| T6 | show_retention_policy shows tiered config | PASS |

### 6. test_monitoring (7 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | lakets_metrics returns rows | PASS |
| T2 | database_size_bytes metric exists and > 0 | PASS |
| T3 | query_stats doesn't error | PASS |
| T4 | chunk_health returns rows with correct counts | PASS |
| T5 | chunk_health reports compressed chunks | PASS |
| T6 | lakets_metrics includes all expected metric names | PASS |
| T7 | chunk_health oldest/newest timestamps are valid | PASS |

### 7. test_shadow_sync (5 tests)

| Test | Description | Result |
|------|-------------|--------|
| TEST 1 | Shadow table created | PASS |
| TEST 2 | REPLICA IDENTITY FULL set | PASS |
| TEST 3 | Rows forwarded to shadow table | PASS |
| TEST 4 | Registry updated correctly | PASS |
| TEST 5 | disable_sync cleans up | PASS |

### 8. test_metric_table (7 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | create_metric_table returns valid ID | PASS |
| T2 | Data inserted (500 rows) | PASS |
| T3 | Series index exists | PASS |
| T4 | BRIN index exists | PASS |
| T5 | Cardinality detection (host=5) | PASS |
| T6 | Cardinality status OK | PASS |
| T7 | Cardinality warning at max threshold | PASS |

### 9. test_lvc (5 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | LVC cache table created | PASS |
| T2 | Cache populated with entries | PASS |
| T3 | Upsert updates cached value | PASS |
| T4 | cached_series count correct | PASS |
| T5 | LVC disabled, registry empty | PASS |

### 10. test_downsample (6 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | create_downsample_pipeline returns ID | PASS |
| T2 | show_downsample_pipelines finds pipeline | PASS |
| T3 | query_auto_resolution returns options | PASS |
| T4 | Auto-resolution includes raw source | PASS |
| T5 | drop_downsample_pipeline removes pipeline | PASS |
| T6 | Duplicate pipeline name rejected | PASS |

### 11. test_alerts (4 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | Alerts fired for threshold breach | PASS |
| T2 | alert_data contains expected keys | PASS |
| T3 | No alerts for impossible threshold | PASS |
| T4 | Deadman switch detects stale hosts | PASS |

### 12. test_ingest (7 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | ingest_batch inserts rows | PASS |
| T2 | ingest_batch rejects non-array | PASS |
| T3 | ingest_prometheus works correctly | PASS |
| T4 | Ingested data is queryable | PASS |
| T5 | ingest_batch with NULL values | PASS |
| T6 | Empty batch returns 0 | PASS |
| T7 | Numeric JSON types handled | PASS |

### 13. test_rollup_optimization (25 tests)

| Test | Description | Result |
|------|-------------|--------|
| T13 | _detect_bucket_column returns bucket | PASS |
| T14 | _get_dirty_chunks returns dirty chunks | PASS |
| T15 | _inject_time_predicate adds WHERE clause | PASS |
| T16 | _inject_time_predicate falls back on invalid query | PASS |
| T17 | _refresh_buckets_batch refreshes dirty buckets | PASS |
| T18 | _refresh_buckets_chunked handles chunked processing | PASS |
| T19 | create_rollup stores depends_on | PASS |
| T20 | _build_rollup_dag returns correct topological order | PASS |
| T21 | _build_rollup_dag detects cycles | PASS |
| T22 | refresh_rollup_cascade refreshes in dependency order | PASS |
| T23 | _resolve_bucket_tier returns correct tier | PASS |
| T24 | invalidate_rollup_range auto-detects tier | PASS |
| T25 | Bulk INSERT creates invalidation entries | PASS |
| T26 | enable/disable/show_rollup_exports | PASS |
| T27 | refresh_rollup batch-processes invalidation entries | PASS |
| T28 | show_rollup_dag returns entries | PASS |
| T29 | _refresh_buckets_batch returns 0 for empty input | PASS |
| T30 | _detect_bucket_column falls back on invalid SQL | PASS |
| T31 | Self-dependency rejected | PASS |
| T32 | Nonexistent dependency rejected | PASS |
| T33 | Invalid export_mode rejected | PASS |
| T34 | _refresh_buckets_chunked returns 0 for empty input | PASS |
| T35 | _inject_time_predicate with existing WHERE clause | PASS |
| T36 | NULL time_column returns original query | PASS |
| T37 | 3-level DAG order: min->hour->day | PASS |

---

## Bugs Found and Fixed During Testing

### 1. `_inject_time_predicate` PCRE vs POSIX regex (CRITICAL)

**File:** `sql/13_rollup_optimization.sql`
**Issue:** Used `\b` for word boundaries (PCRE syntax), but PostgreSQL uses POSIX regex where `\b` means backspace character. This caused the regex to never match, making the function always fall back to the original query without predicate injection.
**Fix:** Replaced `\b` with `\y` (PostgreSQL's POSIX word boundary).
**Impact:** Scan-level partition pruning was silently disabled for all rollup refresh operations.

### 2. `_ensure_partitions` parameter name mismatch

**File:** `sql/01_chronotable.sql`
**Issue:** Database had old function signature with `p_hypertable_id` parameter while code used `p_chronotable_id`.
**Fix:** Dropped old function signature before reinstall.

### 3. `_first_last_state` type not idempotent

**File:** `sql/02_timeseries_functions.sql`
**Issue:** `CREATE TYPE` doesn't support `IF NOT EXISTS`. Repeated installs failed.
**Fix:** Added conditional drop+recreate block.

### 4. Schema migration: `hypertable_id` -> `chronotable_id`

**Tables:** `_chunk_metadata`, `_policy_registry`
**Issue:** Old `hypertable_id` column coexisted with new `chronotable_id` (nullable).
**Fix:** Migrated data, set NOT NULL constraint, dropped old column.

### 5. MySQL syntax in tests: `UPDATE ... LIMIT 1`

**File:** `tests/test_rollup_optimization.sql`
**Issue:** `LIMIT` in `UPDATE` is MySQL syntax, not PostgreSQL.
**Fix:** Used `WHERE ctid = (SELECT ctid ... LIMIT 1)` pattern.

### 6. Missing table creation in test setup

**Files:** `tests/test_rollup.sql`, `tests/test_rollup_optimization.sql`
**Issue:** `create_chronotable` requires a pre-existing table.
**Fix:** Added `CREATE TABLE` + data INSERT before `create_chronotable` calls.

---

## Module Coverage

| Module | SQL File | Test File | Functions Tested |
|--------|----------|-----------|-----------------|
| 00 Schema | 00_schema.sql | (implicit) | Schema creation verified by all tests |
| 01 ChronoTable | 01_chronotable.sql | test_chronotable.sql | create_chronotable, drop_chunks, alter_chunk_interval |
| 02 Time-Series Functions | 02_timeseries_functions.sql | test_timeseries_functions.sql | time_bucket, first, last, gapfill, locf, interpolate, delta, rate, histogram |
| 03 RollUp Engine | 03_rollup.sql | test_rollup.sql | create_rollup, refresh_rollup, drop_rollup, show_rollups, invalidate_rollup_range |
| 04 Compression | 04_compression.sql | test_compression.sql | add/remove/show_compression_policy, compress/decompress_chunk |
| 05 Retention | 05_retention.sql | test_retention.sql | add/remove/show_retention_policy, apply_retention |
| 06 Monitoring | 06_monitoring.sql | test_monitoring.sql | lakets_metrics, chunk_health, query_stats |
| 07 Shadow Sync | 07_shadow_sync.sql | test_shadow_sync.sql | enable_sync, disable_sync, shadow table forwarding |
| 08 Metric Table | 08_metric_table.sql | test_metric_table.sql | create_metric_table, cardinality checks, index creation |
| 09 LVC | 09_lvc.sql | test_lvc.sql | enable/disable_lvc, cache upsert, stats |
| 10 Downsample | 10_downsample.sql | test_downsample.sql | create/drop_downsample_pipeline, query_auto_resolution |
| 11 Alerts | 11_alerts.sql | test_alerts.sql | check_alerts, deadman_switch |
| 12 Ingest | 12_ingest.sql | test_ingest.sql | ingest_batch, ingest_prometheus |
| 13 RollUp Optimization | 13_rollup_optimization.sql | test_rollup_optimization.sql | All M23-M28 functions (25 tests) |
| 14 Hardening | 00_schema, 01_chronotable, 11_alerts | test_security_hardening.sql | Schema completeness, indexes, constraints, input validation |
| 15 Python Patterns | databricks/workflows/*.py | test_python_patterns.py | SQL query construction safety, connection handling |

---

### 14. test_security_hardening (13 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | _lvc_registry table exists with correct columns | PASS |
| T2 | _downsample_registry table exists with correct columns | PASS |
| T3 | create_chronotable alias works | PASS |
| T4 | _resolve_partition_parent returns correct parent | PASS |
| T5 | uq_chunk_metadata_ct_range unique constraint exists | PASS |
| T6 | idx_chunk_metadata_chunk_name unique index exists | PASS |
| T7 | valid_export_mode CHECK constraint rejects invalid values | PASS |
| T8 | ON CONFLICT target validated by constraint existence | PASS |
| T9 | alert_deadman rejects invalid p_group_by input | PASS |
| T10 | column_default injection guard verified | PASS |
| T11 | _resolve_partition_parent returns NULL for non-partition | PASS |
| T12 | idx_chunk_metadata_ct_status_range covering index exists | PASS |
| T13 | idx_rollup_registry_source_ct partial index exists | PASS |

### 15. test_python_patterns (15 tests)

| Test | Description | Result |
|------|-------------|--------|
| T1 | rollup_export: no f-string SQL in filter | PASS |
| T2 | rollup_export: _export_full uses sql.Identifier | PASS |
| T3 | rollup_export: _export_incremental uses sql.Identifier | PASS |
| T4 | rollup_export: _validate_identifier function exists | PASS |
| T5 | cold_rollup_refresh: validates bucket_col | PASS |
| T6 | cold_rollup_refresh: DELETE uses sql.Identifier | PASS |
| T7 | cold_rollup_refresh: INSERT uses sql.Identifier | PASS |
| T8 | cold_rollup_refresh: tracks failures | PASS |
| T9 | compression_job: DROP TABLE uses sql.Identifier | PASS |
| T10 | compression_job: uses _chronotable_registry | PASS |
| T11 | compression_job: no dead jdbc_url code | PASS |
| T12 | lakebase_utils: connect_timeout present | PASS |
| T13 | lakebase_utils: statement_timeout present | PASS |
| T14 | lakebase_utils: cursor cleanup on error | PASS |
| T15 | rollup_refresh: tracks failures | PASS |

> Python tests run without a live database: `python3 -m pytest tests/test_python_patterns.py -v`

---

## Test Execution Details

- **Execution time:** ~51 seconds for full suite
- **Database:** Lakebase provisioned instance (CU_1)
- **PostgreSQL version:** 16.12
- **Connection:** Lakebase endpoint (redacted)
- **psql version:** 18.3 (Homebrew)
