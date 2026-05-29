# Design: Sync RollUps to Unity Catalog via Lakebase CDF

**Date:** 2026-05-29
**Status:** Approved
**Author:** Taran

## Problem

LakeTS exposes RollUp aggregate tables to Unity Catalog through a **custom export +
registration path ("Path B")**:

- `enable_rollup_export` / `disable_rollup_export` / `show_rollup_exports`
  (`sql/14_rollup_optimization.sql`)
- `sql/15_uc_integration.sql` — `_uc_registry` plus
  `register_uc_table` / `tag_uc_table` / `get_uc_registrations` / `unregister_uc_table`
- Databricks jobs `databricks/workflows/rollup_export.py` and
  `databricks/workflows/uc_registration.py`

This couples Lakebase to UC by a **free-text, unvalidated, mutable table name**, with
no foreign key to the stable `_rollup_registry.id` and no UC `table_id`. Consequences:

- **No validation** that the UC catalog/schema/table exists at registration time.
- **UC → Lakebase drift**: a rename/drop/recreate on the UC side is invisible to
  Lakebase. `_ensure_uc_table` does `CREATE TABLE IF NOT EXISTS` by name path
  (`uc_registration.py:127`), so a renamed UC table is silently recreated empty.
- **Asymmetric lifecycle**: `unregister_uc_table` does not drop the UC table, and
  dropping the UC table does not unregister — the two systems leak apart.

Root cause: two systems of record coupled by a name that only LakeTS tracks and only
Databricks owns.

## Decision

Replace Path B with **Lakebase CDF (Path A)** — the same native mechanism
ChronoTables already use. Databricks owns the Postgres↔UC mapping end-to-end, so the
drift/consistency problem disappears. No table IDs and no reconciliation job are
required. Users opt a RollUp into UC sync with the **same API used for ChronoTables**:
`lakets.enable_sync('<rollup_name>')`.

### Platform constraints (from the Lakebase CDF docs)

- *"For a Lakebase table to participate in CDF, it must have `REPLICA IDENTITY FULL`
  set."* — this is the per-table participation switch.
- *"Lakebase partitioned tables are not supported. A schema that contains partitioned
  tables causes those tables to fail."* — a schema-wide hazard.
- CDF is started on a **schema** (destination catalog/schema chosen there).

The partitioned-table rule is the crux: `public` holds the partitioned ChronoTable
parents, so CDF cannot be enabled on `public`.

## Architecture: uniform shadow pattern, isolated in `lakets_cdf`

**Principle:** every synced table — ChronoTable *or* RollUp, partitioned or not — is
mirrored by an unpartitioned **shadow table in a dedicated, partition-free schema
`lakets_cdf`** (name is adjustable). CDF runs **only on `lakets_cdf`**. Source tables
never move.

This is a **deliberately removable workaround**. `lakets_cdf` + shadows + triggers
exist solely because of the partitioned-table limitation. When Lakebase lifts it, the
entire layer can be torn down and source tables synced directly — a single clean
teardown, because there is exactly one mechanism, not two.

| Synced table | Source (unchanged) | Shadow (new, CDF-replicated) |
|---|---|---|
| ChronoTable | `public.<name>` (partitioned) | `lakets_cdf._shadow_<name>` |
| RollUp | `public._rollup_<name>` (unpartitioned) | `lakets_cdf._shadow_rollup_<name>` |

The partitioned ChronoTable parents stay in `public` and never enter the CDF schema,
so the partitioned-table failure rule never triggers.

## Design

### 1. Generalize `enable_sync` / `disable_sync`

`enable_sync(p_table_name, p_schema_name DEFAULT 'public')` becomes a dispatcher that
resolves the table type and delegates to focused internal helpers:

```
enable_sync(p_table_name, p_schema_name := 'public'):
  found_ct := EXISTS in _chronotable_registry WHERE schema_name=p_schema_name AND table_name=p_table_name
  found_ru := EXISTS in _rollup_registry      WHERE name=p_table_name
  if found_ct AND found_ru -> RAISE 'ambiguous: % is both a ChronoTable and a RollUp'
  elif found_ct            -> _enable_chronotable_sync(p_table_name, p_schema_name)
  elif found_ru            -> _enable_rollup_sync(p_table_name)
  else                     -> RAISE '% is not a registered ChronoTable or RollUp'
```

ChronoTables resolve on `(schema_name, table_name)`; RollUps resolve on `name` (they
always live in `public`). Collisions are rejected, never guessed. `disable_sync` uses
identical resolution.

### 2. Shared shadow setup (both types)

Both helpers call a shared routine that:

1. Determines the source table (ChronoTable parent or `_rollup_<name>`, both in
   `public`).
2. Creates an unpartitioned shadow in `lakets_cdf` mirroring the source columns.
3. `ALTER TABLE lakets_cdf.<shadow> REPLICA IDENTITY FULL` — **run by the sync command
   itself, per table.**
4. Installs an `AFTER INSERT OR UPDATE OR DELETE` trigger on the source forwarding to
   the shadow (see §3).
5. Records the shadow name + `sync_enabled = TRUE` in the relevant registry.

`disable_sync` drops the trigger + shadow and clears the flag.

**Idempotency** on two levels: `ALTER TABLE ... REPLICA IDENTITY FULL` is inherently a
no-op when already FULL; and each helper checks `sync_enabled` first, short-circuiting
repeat `enable_sync`/`disable_sync` calls with a `NOTICE` rather than erroring.

### 3. Trigger semantics: true mirror (correction)

The existing trigger (`_sync_trigger_fn`, `sql/13_shadow_sync.sql:33-41`) is
**append-only** — it `INSERT`s into the shadow on every operation, including DELETE.
That loses deletes. It is acceptable for append-only sensor data but **wrong for
RollUps**, whose incremental refresh performs `DELETE + INSERT` of dirty buckets
(`sql/04_rollup.sql:170-174`).

The trigger becomes a **true mirror**: `INSERT→INSERT`, `UPDATE→UPDATE`,
`DELETE→DELETE` on the shadow. CDC on the shadow (which carries `REPLICA IDENTITY
FULL`) then reflects rollup deletes accurately. This also justifies the existing
`REPLICA IDENTITY FULL` on shadows, which is only meaningful when the shadow receives
updates/deletes.

The trigger must continue to resolve partitioned ChronoTable writes (the trigger fires
on child partitions; `_resolve_partition_parent` maps partition → parent), and now
also handle unpartitioned RollUp writes (`TG_TABLE_NAME` is the rollup table directly).
Shadow-name resolution covers both registries (or a unified shadow-map lookup, to be
finalized in the plan).

### 4. ChronoTable shadow relocation (latent-bug fix)

Today's shadows are created in `public` (`sql/13_shadow_sync.sql:92`), alongside the
partitioned parents — so enabling CDF on `public` would already fail. Shadows move to
`lakets_cdf`. `_enable_chronotable_sync` and the trigger's shadow resolution update
accordingly.

### 5. Table-level granularity

Sync is controlled **per table**, never per schema, by our functions. The opt-in
switch is `REPLICA IDENTITY FULL` on the specific shadow table. Schema-level CDF
enablement on `lakets_cdf` (Lakebase UI) is a one-time infra prerequisite; only tables
with a shadow + replica identity participate.

### 6. CDF destination

CDF replicates each shadow to a UC Managed Table `lb_<shadow_name>_history`
(append-only change feed: `_pg_change_type`, `_pg_lsn`, `_pg_xid`, `_timestamp`). The
name is derivable and not stored. Databricks owns its lifecycle.

### 7. Registry changes (`_rollup_registry`)

- **Drop** (Path B): `export_enabled`, `export_delta_table`, `export_mode`,
  `last_exported_at` (`sql/14_rollup_optimization.sql:24-27`).
- **Add**: `sync_enabled BOOLEAN NOT NULL DEFAULT FALSE` and `shadow_table_name TEXT`
  (mirroring `_chronotable_registry`).

`create_rollup`, `refresh_rollup`, and the realtime views are **unchanged** — RollUps
stay in `public`; the shadow is purely additive.

### 8. Removals (Path B)

- Delete `sql/15_uc_integration.sql` and its entry in `sql/99_install.sql`.
- Delete `enable_rollup_export` / `disable_rollup_export` / `show_rollup_exports` and
  the export `ADD COLUMN`s from `sql/14_rollup_optimization.sql`.
- Delete `databricks/workflows/rollup_export.py` and
  `databricks/workflows/uc_registration.py`, plus their bundle/job entries.
- Delete `tests/test_uc_integration.sql`; remove export blocks from
  `tests/test_rollup_optimization.sql` and `tests/test_security_hardening.sql`.

### 9. Install

- Add `CREATE SCHEMA IF NOT EXISTS lakets_cdf` to the install path
  (`sql/99_install.sql` / earliest schema module).

### 10. Documentation

- Replace `website/docs/how-to/export-to-uc.md` with **"Sync RollUps to Unity
  Catalog"** — `SELECT lakets.enable_sync('metrics_hourly');`, the shadow/`lakets_cdf`
  model, the `lb_<shadow>_history` destination shape, and the per-table opt-in.
- Fold `website/docs/reference/unity-catalog.md` into
  `website/docs/reference/lakebase-cdf.md`: `enable_sync`/`disable_sync` now accept
  RollUps; document the `lakets_cdf` schema and its future removability.
- Fix Path B mentions in `website/docs/glossary.md`,
  `website/docs/guides/how-it-works/rollups.md`,
  `website/docs/reference/rollups.md`, `website/docs/reference/metadata-tables.md`.

## Testing

`tests/test_rollup_sync.sql`:

- `enable_sync('<rollup>')` → asserts shadow exists in `lakets_cdf`, shadow has
  `REPLICA IDENTITY FULL` (`pg_class.relreplident = 'f'`), trigger installed on the
  source, `sync_enabled = TRUE`, `shadow_table_name` recorded.
- `enable_sync` again → no error, remains enabled (idempotent).
- Source `DELETE` propagates a delete to the shadow (true-mirror behavior).
- `disable_sync` → trigger + shadow dropped, `sync_enabled = FALSE`.
- `disable_sync` again → no error (idempotent).
- `enable_sync('<unknown>')` → raises "not a registered ChronoTable or RollUp".
- Regression: ChronoTable shadow-sync tests pass with shadows now in `lakets_cdf` and
  true-mirror trigger semantics.
- `cd website && npm run build` succeeds.

## Out of scope

- Removing `refresh_mode` / the full-refresh `TRUNCATE` path — separate follow-on spec
  (touches schema, partial index, `create_rollup`, the refresh job, invalidation
  guards, monitoring). UC sync does not depend on it; the incremental path is already
  CDC-safe.
- Any table-ID / drift-reconciliation design (obsoleted by adopting CDF).

## Migration notes

Pre-1.0 (v0.1.x); internal `_`-prefixed tables.

- Registry: `ALTER TABLE lakets._rollup_registry DROP COLUMN export_* , ADD COLUMN
  sync_enabled ..., ADD COLUMN shadow_table_name ...`.
- Existing ChronoTable shadows are recreated in `lakets_cdf` (drop from `public`,
  recreate via `enable_sync`), and the trigger upgraded to true-mirror semantics.
- Existing RollUps gain shadows on the next `enable_sync` call; no relocation.
- `_uc_registry` rows are discarded — the UC tables they tracked are unaffected and can
  be re-synced via `enable_sync` if still desired.

## Future cleanup hook

When Lakebase lifts the partitioned-table CDF limitation: drop `lakets_cdf`, all
shadows, and all forwarding triggers; set `REPLICA IDENTITY FULL` directly on source
tables; CDF then replicates sources directly. Single teardown, no dual code paths.
