# Changelog

All notable changes to LakeTS are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

## [0.1.1] - 2026-06-08

### Fixed

- **Sync/tiering no longer require `USAGE` on the Lakebase-managed `wal2delta` schema.** `enable_sync()` previously aborted with `permission denied for schema wal2delta` when the connected role couldn't see the CDF subsystem schema. The CDF probe now tolerates `insufficient_privilege`: `enable_sync()` warns and continues (the shadow and trigger are created as usual), and the tiering durability gate fails closed (it evicts nothing it cannot verify). See [Troubleshooting](https://databricks-solutions.github.io/lakets/troubleshooting) for the grants needed if you want CDF-gated tiering to evict.

Upgrade by reinstalling `dist/lakets.sql` (the change is function-level — no schema migration required).

## [0.1.0] - 2026-06-05

Initial public release. LakeTS turns Databricks Lakebase (PostgreSQL 17+) into a
time-series database — pure PL/pgSQL, no custom extensions.

### Added

- **ChronoTables** — automatic time-based partitioning via `create_chronotable()`, plus multi-metric (tag + field) tables via `create_metric_table()`.
- **Time-series functions** — `time_bucket`, `time_bucket_gapfill`, `first`/`last` aggregates, `locf`, `interpolate`, `delta`, `rate`, and `histogram`.
- **RollUp engine** — incremental aggregates with watermark-driven refresh, per-bucket invalidation tracking, chunk-skip pruning, and DAG-ordered cascade refresh.
- **Last Value Cache** — sub-10ms latest-state lookups via `enable_lvc()`.
- **Lifecycle** — policy-driven tiering that flags chunks once durable in Unity Catalog, and retention that drops Lakebase partitions only after CDF confirms durability (with a force override).
- **Unity Catalog sync** — `enable_sync()` mirrors ChronoTables and RollUps to Unity Catalog through Lakebase CDF via an unpartitioned shadow table.
- **Alerts** — SQL-native `alert_check()` and `alert_deadman()`.
- **Bulk ingest** — `ingest_batch()` for JSONB arrays and `ingest_prometheus()`.
- **Monitoring** — Prometheus-compatible metrics, `chunk_health()`, and a Databricks AI/BI dashboard.
- **Databricks jobs** — serverless maintenance for partitioning, RollUp refresh, tiering, and retention.
