# Changelog

All notable changes to LakeTS are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

---

## [0.1.2] - 2026-04-13

### Changed

- **SQL module renumbering** — Renumbered all SQL modules to gap-free sequential order (00-15) for clarity. `00_schema` → `01_schema`, `01_chronotable` → `02_chronotable`, through `14_uc_integration` → `15_uc_integration`. Module install order unchanged.
- **`build.sh`** — Updated to reference new file numbers.
- **`99_install.sql`** — Updated include order to match renumbered modules.
- **`CLAUDE.md`** — Updated module architecture table with new numbering.

### Added

- **`docs/LakeTS_Function_Reference.md`** — Comprehensive function reference document covering all LakeTS public and internal functions.

---

## [0.1.1] - 2026-03-29

### Added

- **`_lvc_registry` metadata table** — Tracks Last Value Cache configurations (key/value columns, cache table names). Previously referenced by `09_lvc.sql` but never created.
- **`_downsample_registry` metadata table** — Tracks multi-resolution downsampling pipeline metadata. Previously referenced by `10_downsample.sql` but never created.
- **`_resolve_partition_parent()` helper** — Shared function to resolve partition parent table from `pg_inherits`. Replaces 4 duplicate inline queries across trigger functions.
- **`create_chronotable()` V2 alias** — SQL alias for `create_hypertable()`, providing the canonical V2 naming.
- **Advisory locks on `refresh_rollup`** — Prevents concurrent refresh of the same RollUp via `pg_try_advisory_xact_lock`.
- **Advisory lock on `disable_rollup_invalidation`** — Serializes invalidation cleanup to prevent race conditions.
- **`_touch_chunk_metadata` trigger installation** — `enable_rollup_invalidation()` now installs the M23 chunk-skip trigger on existing partitions, making `_get_dirty_chunks()` functional.
- **Unique constraint `uq_chunk_metadata_ct_range`** — On `(chronotable_id, range_start)` for `_ensure_partitions` ON CONFLICT clause.
- **Unique index `idx_chunk_metadata_chunk_name`** — For fast trigger lookups by chunk name.
- **Partial index `idx_rollup_registry_source_ct`** — On `(source_chronotable_id, refresh_mode)` WHERE incremental, for invalidation trigger performance.
- **Partial index `idx_policy_registry_ct_type`** — On `(chronotable_id, policy_type)` WHERE enabled, for compression/retention job performance.
- **CHECK constraint `valid_export_mode`** — Ensures `export_mode` is either `'full'` or `'incremental'`.
- **Covering index `idx_chunk_metadata_ct_status_range`** — Replaces `idx_chunk_metadata_ct_status` with a covering index including `range_start` and `range_end`.
- **`sql/15_uc_integration.sql`** — Unity Catalog Integration module: `register_uc_table()`, `tag_uc_table()`, `get_uc_registrations()`, `unregister_uc_table()`, and `_uc_registry` metadata table for tracking Delta exports in Unity Catalog.
- **`databricks/workflows/uc_registration.py`** — Workflow job that ensures Delta tables exist in Unity Catalog and applies tags via the Databricks REST API.
- **`sql/migrate.sql`** — Migration runner for upgrading existing installations without a full reinstall.
- **`migrations/V010_V011_security_hardening.sql`** — Idempotent migration script (v0.1.0 → v0.1.1): adds missing DDL tables, indexes, columns, and records the upgrade in `_version`.
- **CI workflow** (`.github/workflows/ci.yml`) — PR validation with SQL lint, Python security lint, secret scan, and Python unit tests.
- **`requirements.txt`** — Python dependency manifest for workflow jobs (`databricks-sdk`, `psycopg2-binary`).
- **`tests/test_security_hardening.sql`** — 13 SQL test cases covering schema completeness, indexes, constraints, and input validation.
- **`tests/test_python_patterns.py`** — 15 Python unit tests validating safe SQL query construction patterns across all workflow files.
- **Connection timeouts** — `lakebase_utils.py` now includes `connect_timeout=30s`, `statement_timeout=10m`, `lock_timeout=30s`.
- **Failure tracking** — All Python workflow jobs (`rollup_refresh`, `rollup_export`, `cold_rollup_refresh`) now accumulate and log failures.

### Fixed

- **Scoped invalidation log DELETE** — `refresh_rollup` now deletes only processed invalidation entries (`bucket_start < v_dirty_from`), preventing race conditions with concurrent writers.
- **Input validation in `alert_deadman`** — `p_group_by` parameter is validated as a simple column name to prevent dynamic SQL injection.
- **Safe value formatting in `ingest_batch`** — All value types now use `format('%L')` for proper literal escaping.
- **Column default guard in `create_hypertable`** — Rejects column defaults containing SQL metacharacters (`;`, `--`, `/*`).
- **Python SQL injection fixes** — All workflow files now use `psycopg2.sql.Identifier` for table/column names and parameterized queries for values, replacing f-string SQL construction.
- **`compression_job.py` table references** — Fixed `_hypertable_registry` to `_chronotable_registry` and `hypertable_id` to `chronotable_id`.
- **Dead code removal** — Removed unused `jdbc_url` assignment from `compression_job.py`.
- **Context manager cleanup** — `lakebase_cursor()` now properly nests `try/finally` for both connection and cursor cleanup.

### Changed

- **GitHub Actions pinned to commit SHAs** — `actions/checkout` and `softprops/action-gh-release` pinned to specific commits for supply chain security.
- **`rollup_export.py` filter clause** — Uses parameterized query instead of f-string interpolation for rollup name filtering.

---

## [0.1.0] - 2026-03-26

### Added

- Initial release of LakeTS time series toolkit
- 14 SQL modules: ChronoTable, time series functions, RollUp engine, compression, retention, monitoring, shadow sync, metric tables, LVC, downsampling, alerts, ingest, RollUp optimization (M23-M28)
- 6 Databricks workflow jobs for automated partition management, compression, retention, rollup refresh, cold-tier re-aggregation, and export
- Build system for single-file distribution (`make build`)
- GitHub Actions release workflow
- 118 SQL test cases across 13 suites

---

[Unreleased]: https://github.com/databricks-solutions/lakets/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/databricks-solutions/lakets/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/databricks-solutions/lakets/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/databricks-solutions/lakets/releases/tag/v0.1.0
