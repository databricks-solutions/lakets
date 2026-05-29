# Design: Remove `refresh_mode` — RollUps are always incremental

**Date:** 2026-05-29
**Status:** Approved
**Author:** Taran

## Problem

Each RollUp carries a `refresh_mode` (`'full'` | `'incremental'`) that selects a refresh
**strategy** in `lakets.refresh_rollup`:

- `'full'` — `TRUNCATE` the RollUp table + re-`INSERT` the whole query result.
- `'incremental'` — `DELETE` + re-`INSERT` only the dirty bucket window (watermark-based,
  plus the invalidation log).

In practice RollUps are always incremental. The `'full'` path is also **CDC-hostile**:
`TRUNCATE` emits no row-level WAL events, so a RollUp that is both `'full'` and CDF-synced
would corrupt its `lakets_cdf` shadow. The toggle is therefore an unused-in-practice,
foot-gun-y option that complicates the refresh code, the schema, monitoring, and the
invalidation guard.

## Decision

Remove the `refresh_mode` toggle and the `'full'`/`TRUNCATE` strategy entirely.
`lakets.refresh_rollup` keeps its responsibility (recompute RollUp aggregates) but **always
runs the incremental strategy**. This is independent of UC sync (already shipped) — it is a
standalone cleanup that also eliminates the CDC-hostile path.

`refresh_rollup` itself (the incremental logic) is unchanged in behavior.

## Changes

### Schema — `sql/01_schema.sql`
- Drop the `refresh_mode TEXT NOT NULL DEFAULT 'incremental'` column from `_rollup_registry`.
- Drop the `valid_refresh_mode` CHECK constraint (goes with the column).
- Change the partial index `(source_chronotable_id, refresh_mode) WHERE refresh_mode='incremental'`
  to a plain index on `(source_chronotable_id)`.

### RollUp engine — `sql/04_rollup.sql`
- `create_rollup`: remove the `p_refresh_mode TEXT DEFAULT 'incremental'` parameter. New
  signature: `create_rollup(p_name, p_query, p_bucket_interval DEFAULT '1 hour',
  p_source_table DEFAULT NULL, p_source_schema DEFAULT 'public', p_depends_on DEFAULT '{}')`.
  Remove `refresh_mode` from the `_rollup_registry` INSERT column/value lists.
- `refresh_rollup`: delete the `IF v_rec.refresh_mode = 'full' THEN TRUNCATE+INSERT` branch;
  keep only the incremental body (de-indented, no longer inside the `ELSE`).
- `show_rollups()`: remove `refresh_mode` from the `RETURNS TABLE (...)` and the `SELECT`.
- Remove the two `AND r.refresh_mode = 'incremental'` filter predicates (the queries now apply
  to all RollUps).
- `enable_rollup_invalidation`: remove the lookup of `refresh_mode` and the
  `IF v_mode != 'incremental' THEN RAISE EXCEPTION ...` guard (all RollUps are incremental).

### Optimization — `sql/14_rollup_optimization.sql`
- Remove the one `AND r.refresh_mode = 'incremental'` filter predicate.

### Monitoring — `sql/07_monitoring.sql`
- Remove the `'refresh_mode', r.refresh_mode` key from the `jsonb_build_object(...)` blob.

### Databricks job — `databricks/workflows/rollup_refresh.py`
- Remove `refresh_mode` from the `SELECT ... FROM lakets._rollup_registry`.
- Remove `rollup["refresh_mode"]` from the "Refreshed: ... (mode=%s)" log line (drop the
  `mode=%s` suffix).

### Docs
- `website/docs/reference/rollups.md`: remove `refresh_mode` from the `create_rollup` parameter
  list and the `show_rollups()` return columns; remove any "full vs incremental" explanation.
- Check `glossary.md` / `guides/how-it-works/rollups.md` for `refresh_mode` / "full refresh"
  mentions and update.
- `CHANGELOG.md`: add a `### Changed`/`### Removed` note.

## Migration

Drop the column unconditionally via `ALTER TABLE lakets._rollup_registry DROP COLUMN IF EXISTS
refresh_mode;` (placed where the column was defined / in the schema module so re-install is
idempotent). Any pre-existing `'full'` RollUp in an upgraded database becomes incremental and
refreshes from its stored watermark on the next `refresh_rollup`. Document that such a RollUp
should be recreated or fully recomputed once if its history needs a full rebuild. Pre-1.0; no
`'full'` RollUps are expected in practice.

## Testing

Add to a test file (e.g. `tests/test_rollup.sql` or a focused block in `tests/test_rollup_sync.sql`):
- `create_rollup` succeeds without a mode argument; `_rollup_registry` has **no** `refresh_mode`
  column (`information_schema.columns` count = 0).
- After inserting new source rows and calling `refresh_rollup`, the RollUp table reflects the
  new data (incremental refresh still works).
- `enable_rollup_invalidation` succeeds on a normal RollUp (no mode guard rejection).

Run the full SQL suite against local Postgres (`lakets_test`) — all pass except the two known
pre-existing environmental failures (`test_ingest.sql`, `test_timeseries_functions.sql`). Build
the docs (`cd website && npm run build`) — no new broken links. Dangling-ref sweep:
`grep -rn "refresh_mode" sql/ databricks/ tests/ website/docs/` → only the intentional
`DROP COLUMN IF EXISTS refresh_mode` migration line (and CHANGELOG history) may remain.

## Out of scope
- `refresh_rollup`'s incremental algorithm (watermark / invalidation / predicate injection) —
  unchanged.
- UC sync, shadows, `lakets_cdf` — already shipped, untouched.

## Execution
Implemented directly on `feat/docs-and-rollup-cdf-sync` (no worktree; small contained change),
subagent-driven with TDD against the local `lakets_test` DB. Merges to main later with the
in-flight docs.
