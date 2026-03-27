# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LakeTS is a time series toolkit for Databricks Lakebase — pure SQL (PL/pgSQL) functions that bring TimescaleDB-equivalent capabilities to PostgreSQL 16+ on Lakebase. No custom extensions. Hot tier (Lakebase) + cold tier (Delta Lake) hybrid architecture.

All SQL objects live in the `lakets` schema.

## Build & Install

```bash
# Build single-file distribution
make build           # → dist/lakets.sql
make checksum        # → dist/lakets.sql.sha256
make clean           # Remove build artifacts

# Install all modules on a Lakebase instance (from source)
psql -h <host> -U <user> -d databricks_postgres -f sql/99_install.sql

# Install from built single file
psql -h <host> -U <user> -d databricks_postgres -f dist/lakets.sql

# Uninstall (drops lakets schema)
psql -h <host> -U <user> -d databricks_postgres -f sql/00_uninstall.sql

# Run a single test suite
psql -h <host> -U <user> -d databricks_postgres -f tests/test_rollup.sql

# Run all tests (sequentially)
for f in tests/test_*.sql; do psql -h <host> -U <user> -d databricks_postgres -f "$f"; done

# Deploy Databricks workflow jobs
databricks bundle deploy -t dev
```

Connection requires a Databricks OAuth token:
```bash
DATABRICKS_TOKEN=$(databricks auth token --host <workspace-url>)
```

## Release Process

1. Update `VERSION` file with new semver
2. Commit: `git commit -am "chore: bump version to X.Y.Z"`
3. Tag: `git tag vX.Y.Z`
4. Push: `git push origin main --tags`
5. GitHub Actions builds `dist/lakets.sql` and creates a Release

## SQL Module Architecture

Modules are numbered and installed in order via `sql/99_install.sql`:

```
00_version.sql          → Version tracking table + upgrade guard (creates lakets schema)
00_schema.sql           → 5 metadata tables
01_chronotable.sql      → Time-partitioned table management (RANGE partitioning)
02_timeseries_functions.sql → time_bucket, first/last aggregates, gapfill, locf, interpolate, delta, rate, histogram
03_rollup.sql           → Incremental aggregation engine (per-bucket refresh + invalidation log)
04_compression.sql      → Tiering policies (Lakebase → Delta)
05_retention.sql        → Retention policies (auto-drop old partitions)
06_monitoring.sql       → Prometheus-compatible metrics
07_shadow_sync.sql      → Lakehouse Sync via shadow table pattern (works around partitioned table limitation)
08_metric_table.sql     → InfluxDB-style tag+field model
09_lvc.sql              → Last Value Cache (trigger-based sub-10ms latest-state)
10_downsample.sql       → Multi-resolution pipeline registry
11_alerts.sql           → SQL-native alert rules
12_ingest.sql           → Batch JSON + Prometheus ingest
13_rollup_optimization.sql → M23-M28: chunk-skip, predicate injection, DAG deps, tier routing, batch refresh, export
```

Module 07 is installed after 12 (not in numeric order) because it depends on functions from later modules.

## Key Metadata Tables (`lakets` schema)

| Table | Tracks |
|-------|--------|
| `_version` | Installed version, timestamp, and module list (version tracking + upgrade guard) |
| `_chronotable_registry` | All time-partitioned tables (1 row per table) |
| `_chunk_metadata` | Individual partitions with status (active/compressed/tiered/dropped) and `last_modified_at` |
| `_rollup_registry` | RollUp definitions: source query, bucket interval, watermark, `depends_on[]`, export config |
| `_rollup_invalidation_log` | Dirty buckets needing re-aggregation, with tier (hot/cold) |
| `_policy_registry` | Compression, retention, tiering policies |

## Naming Conventions

| Object | Pattern | Example |
|--------|---------|---------|
| Partitions | `{table}_{YYYYMMDD_HH24MISS}` | `metrics_20260320_000000` |
| RollUp tables | `_rollup_{name}` | `_rollup_hourly_agg` |
| Real-time views | `_rollup_rt_{name}` | `_rollup_rt_hourly_agg` |
| Shadow tables | `_shadow_{table}` | `_shadow_metrics` |
| LVC cache | `_lvc_{table}` | `_lvc_system_metrics` |
| Internal functions | `_{purpose}` | `_ensure_partitions`, `_inject_time_predicate` |
| Aggregate state types | `_{purpose}_state` | `_first_last_state` |

## Test Framework

Tests are PL/pgSQL anonymous blocks using `ASSERT` statements:
```sql
DO $$ DECLARE v_id INT; BEGIN
    SELECT lakets.create_chronotable('ct_test', 'time', '1 day') INTO v_id;
    ASSERT v_id IS NOT NULL, 'T1 FAILED';
    RAISE NOTICE 'T1 PASSED: create_chronotable id=%', v_id;
END $$;
```

Each test file creates its own test tables, runs assertions, then cleans up with `DROP TABLE ... CASCADE` and `DELETE FROM lakets._*`. Tests are independent and can run in any order.

118 test cases across 13 suites. Test report: `tests/TEST_REPORT.md`.

## Databricks Workflows (`databricks/`)

Python jobs in `databricks/workflows/` connect to Lakebase via `lakebase_utils.py` (OAuth + psycopg2). Scheduled via Asset Bundle (`databricks/bundles/databricks.yml`):

| Job | Schedule | Purpose |
|-----|----------|---------|
| Partition Manager | Every 6h | Pre-create future partitions |
| Compression & Tiering | Daily 2 AM | Tier old chunks to Delta |
| Retention | Daily 3 AM | Drop expired data both tiers |
| RollUp Refresh | Every 15 min | Incremental hot-tier refresh |
| Cold RollUp Refresh | Daily 1 AM | Re-aggregate cold-tier dirty buckets |
| RollUp Export | Daily 4 AM | Export RollUps to Delta |

## Key Design Decisions

- **RANGE partitioning** over manual sharding: native pruning, instant drop, automatic insert routing
- **Separate RollUp tables** (not materialized views): enables surgical per-bucket refresh, DAG cascades, avoids FULL REFRESH bottleneck
- **Shadow table pattern** for Lakehouse Sync: trigger-forwarded unpartitioned table works around partitioned table CDC limitation
- **Invalidation log** for incremental refresh: only recompute dirty buckets, not entire dataset
- **All DDL is idempotent**: `CREATE OR REPLACE`, `IF NOT EXISTS`, `IF EXISTS` — safe to re-run `99_install.sql`

## RollUp Optimization Modules (M23-M28)

These extend `03_rollup.sql` with performance optimizations:
- **M23**: `_touch_chunk_metadata()` trigger tracks `last_modified_at` per chunk; `_get_dirty_chunks()` skips unchanged chunks
- **M24**: `_inject_time_predicate()` adds WHERE clause to source queries for partition pruning (validated via EXPLAIN)
- **M25**: `depends_on[]` column enables DAG-based cascade refresh
- **M26**: Separate `refresh_rollup_hot()` / `refresh_rollup_cold()` paths
- **M27**: `_detect_bucket_column()` auto-discovers bucket column from query output
- **M28**: `_refresh_buckets_batch()` uses DELETE+INSERT instead of row-by-row UPSERT; `rollup_export()` writes to Delta

## Working with SQL

- All functions are in the `lakets` schema — always qualify calls: `lakets.create_chronotable(...)`
- Use `\y` (not `\b`) for word boundaries in PostgreSQL regex
- Custom aggregates (`first`, `last`) require idempotent type recreation (drop aggregate + type, then recreate)
- Predicate injection (M24) uses regex on query text — always validate with EXPLAIN before executing modified queries

## Directory Notes

- `lakets/` — Legacy directory structure (older versions of the same modules). The canonical code is in `sql/`, `tests/`, `databricks/`
- `demo/financial/` — Stock market demo with data generator, 13 benchmarks, and TimescaleDB comparison
- `diagrams/` — Architecture diagrams (Mermaid `.mmd`, DrawIO `.drawio`, and rendered `.png`)
- `scripts/` — Presentation/diagram generation utilities
- PRD files at root: `PRD_LakeTS.md` (V1), `PRD_LakeTS_V2.md`, `PRD_LakeTS_Incremental_Refresh.md`, `PRD_LakeTS_RollUp_Optimization.md`, `PRD_LakeTS_V3_Federation.md`
