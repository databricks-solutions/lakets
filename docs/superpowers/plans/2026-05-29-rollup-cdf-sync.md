# RollUp UC Sync via Lakebase CDF — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom RollUp→UC export path (Path B) with native Lakebase CDF, so RollUps opt into UC sync via the existing `enable_sync` API, with all synced tables isolated in a partition-free `lakets_cdf` schema.

**Architecture:** Every synced table (ChronoTable or RollUp) is mirrored by an unpartitioned shadow table in `lakets_cdf`; a true-mirror trigger forwards source writes to the shadow; CDF runs only on `lakets_cdf` (avoiding the partitioned-table limitation). `enable_sync` dispatches by table type. The shadow layer is a deliberately removable workaround for the partitioned-table CDF limitation.

**Tech Stack:** PostgreSQL 16 / plpgsql (Lakebase), Python (Databricks jobs), Docusaurus (docs). Tests are SQL `DO $$ ... ASSERT ... $$` blocks run via `psql`.

**Reference spec:** `docs/superpowers/specs/2026-05-29-rollup-cdf-sync-design.md`

---

## Prerequisites for the executor

- A dev Lakebase instance with LakeTS installed, reachable via `psql`. Export its
  connection string once: `export LAKETS_URL="postgresql://...:.../databricks_postgres"`
  (generate via `mcp generate_lakebase_credential` for `lakets-timeseries`, or use an
  existing psql connection).
- **Reinstall after SQL changes:** `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql`
- **Run a test file:** `psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/<file>.sql`
  (a passing test prints its `... PASSED` notices and the final summary row; a failure
  raises and exits non-zero because of `ON_ERROR_STOP`).
- Work happens on branch `feat/rollup-cdf-sync` in worktree
  `../timeseries-rollup-cdf-sync`. Commit there.

---

## File Structure

- `sql/01_schema.sql` — add `CREATE SCHEMA IF NOT EXISTS lakets_cdf` (modify).
- `sql/13_shadow_sync.sql` — **rewritten**: registry migration for sync columns,
  `_build_shadow_table`, true-mirror `_sync_trigger_fn`, `enable_sync`/`disable_sync`
  dispatchers, and per-type helpers.
- `sql/04_rollup.sql` — `drop_rollup` tears down the shadow if sync is enabled (modify).
- `sql/14_rollup_optimization.sql` — drop export columns + delete export functions (modify).
- `sql/15_uc_integration.sql` — **deleted**.
- `sql/99_install.sql`, `build.sh` — drop the `15_uc_integration.sql` entry (modify).
- `databricks/workflows/rollup_export.py`, `uc_registration.py` — **deleted**.
- `tests/test_rollup_sync.sql` — **new**.
- `tests/test_shadow_sync.sql` — updated for `lakets_cdf` + true-mirror (modify).
- `tests/test_uc_integration.sql` — **deleted**.
- `tests/test_rollup_optimization.sql`, `tests/test_security_hardening.sql` — remove
  export blocks (modify).
- `website/docs/how-to/export-to-uc.md` — rewritten as "Sync RollUps to Unity Catalog".
- `website/docs/reference/unity-catalog.md` — removed; content folded into
  `website/docs/reference/lakebase-cdf.md`.
- `website/docs/glossary.md`, `guides/how-it-works/rollups.md`,
  `reference/rollups.md`, `reference/metadata-tables.md` — fix Path B mentions.
- `CHANGELOG.md`, `README.md` — update references.

---

## Task 1: Foundation — `lakets_cdf` schema + RollUp registry sync columns

**Files:**
- Modify: `sql/01_schema.sql` (after the `lakets` schema is created)
- Modify: `sql/13_shadow_sync.sql` (top of file — registry migration)
- Test: `tests/test_rollup_sync.sql` (created here, expanded in Task 5)

- [ ] **Step 1: Write the failing test**

Create `tests/test_rollup_sync.sql`:

```sql
-- =============================================================================
-- LakeTS RollUp CDF Sync Tests
-- =============================================================================

-- Test 1: lakets_cdf schema exists
DO $$
DECLARE v_exists BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'lakets_cdf')
    INTO v_exists;
    ASSERT v_exists, 'TEST 1 FAILED: lakets_cdf schema not created';
    RAISE NOTICE 'TEST 1 PASSED: lakets_cdf schema exists';
END $$;

-- Test 2: _rollup_registry has sync columns and no export columns
DO $$
DECLARE v_sync INT; v_shadow INT; v_export INT;
BEGIN
    SELECT count(*) INTO v_sync FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='sync_enabled';
    SELECT count(*) INTO v_shadow FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='shadow_table_name';
    SELECT count(*) INTO v_export FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='export_enabled';
    ASSERT v_sync = 1, 'TEST 2 FAILED: sync_enabled column missing';
    ASSERT v_shadow = 1, 'TEST 2 FAILED: shadow_table_name column missing';
    ASSERT v_export = 0, 'TEST 2 FAILED: export_enabled column still present';
    RAISE NOTICE 'TEST 2 PASSED: registry columns correct';
END $$;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: FAIL on TEST 1 (schema missing) — note Task 4 removes export columns, so TEST 2's export assertion may still fail until then; that is expected at this point.

- [ ] **Step 3: Add the schema**

In `sql/01_schema.sql`, immediately after the line that ensures the `lakets` schema (near the top, e.g. after `CREATE SCHEMA IF NOT EXISTS lakets;` if present, otherwise at the very top of the file body), add:

```sql
-- Dedicated, partition-free schema for CDF shadow tables.
-- CDF is enabled only on this schema; partitioned ChronoTable parents stay in public.
CREATE SCHEMA IF NOT EXISTS lakets_cdf;
```

- [ ] **Step 4: Add the registry sync columns**

At the top of `sql/13_shadow_sync.sql` (after the header comment, before `_sync_trigger_fn`), add:

```sql
-- Sync bookkeeping columns on the RollUp registry (ChronoTable registry already has them).
ALTER TABLE lakets._rollup_registry
    ADD COLUMN IF NOT EXISTS sync_enabled      BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS shadow_table_name TEXT;
```

- [ ] **Step 5: Mirror schema grants for `lakets_cdf`**

Find how the `lakets` schema is granted and replicate for `lakets_cdf`:

Run: `grep -rn "GRANT .* ON SCHEMA lakets\|GRANT USAGE" sql/`
If a grant pattern exists (e.g. `GRANT USAGE ON SCHEMA lakets TO <role>`), add the
equivalent `GRANT USAGE ON SCHEMA lakets_cdf TO <role>` plus default privileges for
tables, in `sql/01_schema.sql` right after the `CREATE SCHEMA lakets_cdf` line. If no
explicit grants exist in the SQL (Lakebase owner-only), skip this step.

- [ ] **Step 6: Run test to verify TEST 1 passes**

Run: `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: TEST 1 PASSED; TEST 2's `sync_enabled`/`shadow_table_name` assertions PASS; the `export_enabled` assertion still FAILS (cleared in Task 4).

- [ ] **Step 7: Commit**

```bash
git add sql/01_schema.sql sql/13_shadow_sync.sql tests/test_rollup_sync.sql
git commit -m "feat(sync): add lakets_cdf schema and RollUp sync registry columns"
```

---

## Task 2: Rewrite shadow sync core (dispatcher, helpers, true-mirror trigger)

**Files:**
- Modify: `sql/13_shadow_sync.sql` (replace `_sync_trigger_fn`, `enable_sync`, `disable_sync`)
- Test: `tests/test_rollup_sync.sql`

- [ ] **Step 1: Write the failing test (append to `tests/test_rollup_sync.sql`)**

```sql
-- Setup: a ChronoTable + an incremental RollUp
DROP TABLE IF EXISTS public.rs_metrics CASCADE;
DELETE FROM lakets._rollup_registry WHERE name = 'rs_hourly';
DELETE FROM lakets._chronotable_registry WHERE table_name = 'rs_metrics';

CREATE TABLE public.rs_metrics (
    time TIMESTAMPTZ NOT NULL,
    sensor TEXT NOT NULL,
    reading DOUBLE PRECISION
);
SELECT lakets.create_hypertable('rs_metrics', 'time', '1 day');
INSERT INTO public.rs_metrics VALUES (now(), 's1', 1.0), (now(), 's2', 2.0);

SELECT lakets.create_rollup(
    'rs_hourly',
    'rs_metrics',
    'SELECT time_bucket(''1 hour'', time) AS bucket, sensor, avg(reading) AS avg_reading
       FROM public.rs_metrics GROUP BY 1, 2',
    '1 hour',
    'incremental'
);

-- Test 3: enable_sync on a RollUp creates a shadow in lakets_cdf with REPLICA IDENTITY FULL
DO $$
DECLARE v_exists BOOLEAN; v_ri CHAR; v_sync BOOLEAN; v_shadow TEXT;
BEGIN
    PERFORM lakets.enable_sync('rs_hourly');

    SELECT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema='lakets_cdf' AND table_name='_shadow_rollup_rs_hourly') INTO v_exists;
    ASSERT v_exists, 'TEST 3 FAILED: rollup shadow not created in lakets_cdf';

    SELECT relreplident INTO v_ri FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
        WHERE n.nspname='lakets_cdf' AND c.relname='_shadow_rollup_rs_hourly';
    ASSERT v_ri = 'f', format('TEST 3 FAILED: replica identity=%s', v_ri);

    SELECT sync_enabled, shadow_table_name INTO v_sync, v_shadow
        FROM lakets._rollup_registry WHERE name='rs_hourly';
    ASSERT v_sync = TRUE, 'TEST 3 FAILED: sync_enabled not true';
    ASSERT v_shadow = '_shadow_rollup_rs_hourly', format('TEST 3 FAILED: shadow=%s', v_shadow);
    RAISE NOTICE 'TEST 3 PASSED: rollup shadow created and registered';
END $$;

-- Test 4: idempotent re-enable does not error
DO $$
BEGIN
    PERFORM lakets.enable_sync('rs_hourly');
    RAISE NOTICE 'TEST 4 PASSED: re-enable is idempotent';
END $$;

-- Test 5: source DELETE propagates a delete to the shadow (true mirror)
DO $$
DECLARE v_before BIGINT; v_after BIGINT;
BEGIN
    INSERT INTO public._rollup_rs_hourly (bucket, sensor, avg_reading)
        VALUES (date_trunc('hour', now()), 'sdel', 9.0);
    SELECT count(*) INTO v_before FROM lakets_cdf._shadow_rollup_rs_hourly WHERE sensor='sdel';
    ASSERT v_before = 1, format('TEST 5 FAILED: insert not mirrored (%s)', v_before);

    DELETE FROM public._rollup_rs_hourly WHERE sensor='sdel';
    SELECT count(*) INTO v_after FROM lakets_cdf._shadow_rollup_rs_hourly WHERE sensor='sdel';
    ASSERT v_after = 0, format('TEST 5 FAILED: delete not mirrored (%s rows remain)', v_after);
    RAISE NOTICE 'TEST 5 PASSED: insert and delete mirrored to shadow';
END $$;

-- Test 6: disable_sync tears down shadow + trigger + flag
DO $$
DECLARE v_exists BOOLEAN; v_sync BOOLEAN; v_trig BIGINT;
BEGIN
    PERFORM lakets.disable_sync('rs_hourly');
    SELECT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema='lakets_cdf' AND table_name='_shadow_rollup_rs_hourly') INTO v_exists;
    ASSERT NOT v_exists, 'TEST 6 FAILED: shadow not dropped';
    SELECT sync_enabled INTO v_sync FROM lakets._rollup_registry WHERE name='rs_hourly';
    ASSERT v_sync = FALSE, 'TEST 6 FAILED: sync_enabled still true';
    SELECT count(*) INTO v_trig FROM pg_trigger
        WHERE tgrelid = 'public._rollup_rs_hourly'::regclass AND tgname='trg_lakets_sync';
    ASSERT v_trig = 0, format('TEST 6 FAILED: %s triggers remain', v_trig);
    RAISE NOTICE 'TEST 6 PASSED: disable_sync cleaned up';
END $$;

-- Test 7: enable_sync on unknown name raises
DO $$
BEGIN
    BEGIN
        PERFORM lakets.enable_sync('does_not_exist');
        ASSERT FALSE, 'TEST 7 FAILED: expected exception not raised';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'TEST 7 PASSED: unknown name raised (%)', SQLERRM;
    END;
END $$;

-- Cleanup
SELECT lakets.drop_rollup('rs_hourly');
DROP TABLE IF EXISTS public.rs_metrics CASCADE;
DELETE FROM lakets._chronotable_registry WHERE table_name='rs_metrics';

SELECT 'ALL ROLLUP SYNC TESTS PASSED' as result;
```

- [ ] **Step 2: Run to verify it fails**

Run: `psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: FAIL on TEST 3 — `enable_sync('rs_hourly')` raises "not a registered ChronoTable" (current code only knows ChronoTables).

- [ ] **Step 3: Replace `_sync_trigger_fn` with a true-mirror, dual-registry version**

In `sql/13_shadow_sync.sql`, replace the entire `_sync_trigger_fn` definition with:

```sql
CREATE OR REPLACE FUNCTION lakets._sync_trigger_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_shadow TEXT;
    v_parent TEXT;
BEGIN
    -- Partition parent (NULL for unpartitioned tables such as RollUps)
    SELECT lakets._resolve_partition_parent(TG_TABLE_SCHEMA, TG_TABLE_NAME) INTO v_parent;

    -- ChronoTable shadow (keyed on parent/table name)
    SELECT shadow_table_name INTO v_shadow
    FROM lakets._chronotable_registry
    WHERE schema_name = TG_TABLE_SCHEMA
      AND table_name = COALESCE(v_parent, TG_TABLE_NAME)
      AND sync_enabled = TRUE;

    -- RollUp shadow (keyed on physical rollup table name)
    IF v_shadow IS NULL THEN
        SELECT shadow_table_name INTO v_shadow
        FROM lakets._rollup_registry
        WHERE rollup_table = TG_TABLE_NAME AND sync_enabled = TRUE;
    END IF;

    IF v_shadow IS NULL THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        EXECUTE format(
            'DELETE FROM lakets_cdf.%I t WHERE ROW(t.*) IS NOT DISTINCT FROM ROW(($1).*)',
            v_shadow) USING OLD;
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        EXECUTE format(
            'DELETE FROM lakets_cdf.%I t WHERE ROW(t.*) IS NOT DISTINCT FROM ROW(($1).*)',
            v_shadow) USING OLD;
        EXECUTE format('INSERT INTO lakets_cdf.%I SELECT ($1).*', v_shadow) USING NEW;
        RETURN NEW;
    ELSE  -- INSERT
        EXECUTE format('INSERT INTO lakets_cdf.%I SELECT ($1).*', v_shadow) USING NEW;
        RETURN NEW;
    END IF;
END;
$$;
```

- [ ] **Step 4: Add the shared shadow builder**

Add after `_sync_trigger_fn` in `sql/13_shadow_sync.sql`:

```sql
-- _build_shadow_table: create an unpartitioned shadow in lakets_cdf mirroring the
-- source columns, with REPLICA IDENTITY FULL for CDC.
CREATE OR REPLACE FUNCTION lakets._build_shadow_table(
    p_src_schema TEXT, p_src_table TEXT, p_shadow_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_col_rec RECORD;
    v_col_defs TEXT := '';
BEGIN
    FOR v_col_rec IN
        SELECT a.attname,
               pg_catalog.format_type(a.atttypid, a.atttypmod) AS col_type,
               a.attnotnull
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_src_schema AND c.relname = p_src_table
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF v_col_defs <> '' THEN v_col_defs := v_col_defs || ', '; END IF;
        v_col_defs := v_col_defs || format('%I %s', v_col_rec.attname, v_col_rec.col_type);
        IF v_col_rec.attnotnull THEN
            v_col_defs := v_col_defs || ' NOT NULL';
        END IF;
    END LOOP;

    EXECUTE format('CREATE TABLE IF NOT EXISTS lakets_cdf.%I (%s)', p_shadow_name, v_col_defs);
    EXECUTE format('ALTER TABLE lakets_cdf.%I REPLICA IDENTITY FULL', p_shadow_name);
END;
$$;
```

- [ ] **Step 5: Replace `enable_sync` with a dispatcher + per-type helpers**

Replace the entire `enable_sync` definition in `sql/13_shadow_sync.sql` with:

```sql
-- enable_sync: dispatch by table type (ChronoTable shadow path or RollUp shadow path).
CREATE OR REPLACE FUNCTION lakets.enable_sync(
    p_table_name TEXT, p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_ct BOOLEAN;
    v_is_ru BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM lakets._chronotable_registry
                  WHERE schema_name = p_schema_name AND table_name = p_table_name) INTO v_is_ct;
    SELECT EXISTS(SELECT 1 FROM lakets._rollup_registry WHERE name = p_table_name) INTO v_is_ru;

    IF v_is_ct AND v_is_ru THEN
        RAISE EXCEPTION 'Ambiguous: % is both a ChronoTable and a RollUp', p_table_name;
    ELSIF v_is_ct THEN
        PERFORM lakets._enable_chronotable_sync(p_table_name, p_schema_name);
    ELSIF v_is_ru THEN
        PERFORM lakets._enable_rollup_sync(p_table_name);
    ELSE
        RAISE EXCEPTION '% is not a registered ChronoTable or RollUp', p_table_name;
    END IF;
END;
$$;

-- _enable_chronotable_sync: shadow in lakets_cdf + trigger on the partitioned parent.
CREATE OR REPLACE FUNCTION lakets._enable_chronotable_sync(
    p_table_name TEXT, p_schema_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_id INT; v_already BOOLEAN; v_shadow TEXT;
BEGIN
    SELECT id, sync_enabled INTO v_id, v_already
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF v_already THEN
        RAISE NOTICE 'ChronoTable %.% is already synced', p_schema_name, p_table_name;
        RETURN;
    END IF;

    v_shadow := '_shadow_' || p_table_name;
    PERFORM lakets._build_shadow_table(p_schema_name, p_table_name, v_shadow);

    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_sync
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._sync_trigger_fn()',
        p_schema_name, p_table_name);

    UPDATE lakets._chronotable_registry
    SET shadow_table_name = v_shadow, sync_enabled = TRUE
    WHERE id = v_id;
END;
$$;

-- _enable_rollup_sync: shadow in lakets_cdf + trigger on the unpartitioned rollup table.
CREATE OR REPLACE FUNCTION lakets._enable_rollup_sync(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_rollup_table TEXT; v_already BOOLEAN; v_shadow TEXT;
BEGIN
    SELECT rollup_table, sync_enabled INTO v_rollup_table, v_already
    FROM lakets._rollup_registry WHERE name = p_rollup_name;

    IF v_already THEN
        RAISE NOTICE 'RollUp % is already synced', p_rollup_name;
        RETURN;
    END IF;

    v_shadow := '_shadow_rollup_' || p_rollup_name;
    PERFORM lakets._build_shadow_table('public', v_rollup_table, v_shadow);

    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_sync
         AFTER INSERT OR UPDATE OR DELETE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._sync_trigger_fn()',
        v_rollup_table);

    UPDATE lakets._rollup_registry
    SET shadow_table_name = v_shadow, sync_enabled = TRUE
    WHERE name = p_rollup_name;
END;
$$;
```

- [ ] **Step 6: Replace `disable_sync` with a dispatcher + per-type helpers**

Replace the entire `disable_sync` definition in `sql/13_shadow_sync.sql` with:

```sql
CREATE OR REPLACE FUNCTION lakets.disable_sync(
    p_table_name TEXT, p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_is_ct BOOLEAN; v_is_ru BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM lakets._chronotable_registry
                  WHERE schema_name = p_schema_name AND table_name = p_table_name) INTO v_is_ct;
    SELECT EXISTS(SELECT 1 FROM lakets._rollup_registry WHERE name = p_table_name) INTO v_is_ru;

    IF v_is_ct AND v_is_ru THEN
        RAISE EXCEPTION 'Ambiguous: % is both a ChronoTable and a RollUp', p_table_name;
    ELSIF v_is_ct THEN
        PERFORM lakets._disable_chronotable_sync(p_table_name, p_schema_name);
    ELSIF v_is_ru THEN
        PERFORM lakets._disable_rollup_sync(p_table_name);
    ELSE
        RAISE EXCEPTION '% is not a registered ChronoTable or RollUp', p_table_name;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION lakets._disable_chronotable_sync(
    p_table_name TEXT, p_schema_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_id INT; v_shadow TEXT; v_sync BOOLEAN;
BEGIN
    SELECT id, shadow_table_name, sync_enabled INTO v_id, v_shadow, v_sync
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT COALESCE(v_sync, FALSE) THEN
        RAISE NOTICE 'ChronoTable %.% is not synced', p_schema_name, p_table_name;
        RETURN;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_sync ON %I.%I', p_schema_name, p_table_name);
    IF v_shadow IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS lakets_cdf.%I', v_shadow);
    END IF;
    UPDATE lakets._chronotable_registry
    SET shadow_table_name = NULL, sync_enabled = FALSE WHERE id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION lakets._disable_rollup_sync(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_rollup_table TEXT; v_shadow TEXT; v_sync BOOLEAN;
BEGIN
    SELECT rollup_table, shadow_table_name, sync_enabled INTO v_rollup_table, v_shadow, v_sync
    FROM lakets._rollup_registry WHERE name = p_rollup_name;

    IF NOT COALESCE(v_sync, FALSE) THEN
        RAISE NOTICE 'RollUp % is not synced', p_rollup_name;
        RETURN;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_sync ON public.%I', v_rollup_table);
    IF v_shadow IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS lakets_cdf.%I', v_shadow);
    END IF;
    UPDATE lakets._rollup_registry
    SET shadow_table_name = NULL, sync_enabled = FALSE WHERE name = p_rollup_name;
END;
$$;
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: TESTS 3–7 PASSED, ending with `ALL ROLLUP SYNC TESTS PASSED`.

- [ ] **Step 8: Commit**

```bash
git add sql/13_shadow_sync.sql tests/test_rollup_sync.sql
git commit -m "feat(sync): generalize enable_sync for RollUps with true-mirror shadows in lakets_cdf"
```

---

## Task 3: `drop_rollup` tears down the shadow

**Files:**
- Modify: `sql/04_rollup.sql` (`drop_rollup`, ~lines 258-280)
- Test: `tests/test_rollup_sync.sql`

- [ ] **Step 1: Write the failing test (append before the final summary in `tests/test_rollup_sync.sql`)**

```sql
-- Test 8: drop_rollup removes the shadow when sync is enabled
DROP TABLE IF EXISTS public.rs_metrics2 CASCADE;
DELETE FROM lakets._rollup_registry WHERE name='rs_hourly2';
DELETE FROM lakets._chronotable_registry WHERE table_name='rs_metrics2';
CREATE TABLE public.rs_metrics2 (time TIMESTAMPTZ NOT NULL, sensor TEXT NOT NULL, reading DOUBLE PRECISION);
SELECT lakets.create_hypertable('rs_metrics2', 'time', '1 day');
INSERT INTO public.rs_metrics2 VALUES (now(), 's1', 1.0);
SELECT lakets.create_rollup('rs_hourly2', 'rs_metrics2',
    'SELECT time_bucket(''1 hour'', time) AS bucket, sensor, avg(reading) AS avg_reading FROM public.rs_metrics2 GROUP BY 1,2',
    '1 hour', 'incremental');
DO $$
DECLARE v_exists BOOLEAN;
BEGIN
    PERFORM lakets.enable_sync('rs_hourly2');
    PERFORM lakets.drop_rollup('rs_hourly2');
    SELECT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema='lakets_cdf' AND table_name='_shadow_rollup_rs_hourly2') INTO v_exists;
    ASSERT NOT v_exists, 'TEST 8 FAILED: shadow survived drop_rollup';
    RAISE NOTICE 'TEST 8 PASSED: drop_rollup removed shadow';
END $$;
DROP TABLE IF EXISTS public.rs_metrics2 CASCADE;
DELETE FROM lakets._chronotable_registry WHERE table_name='rs_metrics2';
```

- [ ] **Step 2: Run to verify it fails**

Run: `psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: FAIL on TEST 8 (shadow table still present after drop).

- [ ] **Step 3: Update `drop_rollup`**

In `sql/04_rollup.sql`, in `drop_rollup`, before the `DELETE FROM lakets._rollup_registry WHERE name = p_name;` line, add a sync teardown using the existing function:

```sql
    -- Tear down CDF sync (drops shadow + trigger) if enabled
    IF EXISTS (SELECT 1 FROM lakets._rollup_registry WHERE name = p_name AND sync_enabled = TRUE) THEN
        PERFORM lakets._disable_rollup_sync(p_name);
    END IF;
```

(Place it after the `DROP TABLE IF EXISTS public.%I` for the rollup table but before deleting the registry row, so `_disable_rollup_sync` can still read `rollup_table`/`shadow_table_name`. Note: dropping the rollup table first also drops its trigger automatically; `_disable_rollup_sync`'s `DROP TRIGGER IF EXISTS` is then a harmless no-op and it still drops the shadow + clears the flag.)

- [ ] **Step 4: Run to verify it passes**

Run: `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: TEST 8 PASSED.

- [ ] **Step 5: Commit**

```bash
git add sql/04_rollup.sql tests/test_rollup_sync.sql
git commit -m "feat(sync): tear down rollup shadow on drop_rollup"
```

---

## Task 4: Remove Path B SQL (export functions, columns, module 15)

**Files:**
- Delete: `sql/15_uc_integration.sql`
- Modify: `sql/14_rollup_optimization.sql` (export `ADD COLUMN`s → `DROP COLUMN`s; delete `enable_rollup_export`, `disable_rollup_export`, `show_rollup_exports`)
- Modify: `sql/99_install.sql`, `build.sh` (remove `15_uc_integration.sql`)
- Delete: `tests/test_uc_integration.sql`

- [ ] **Step 1: Delete module 15 and its references**

```bash
git rm sql/15_uc_integration.sql tests/test_uc_integration.sql
```

In `sql/99_install.sql`, delete the line:
```
\ir 15_uc_integration.sql
```
In `build.sh`, delete the `"15_uc_integration.sql"` entry from the `MODULES` array.

- [ ] **Step 2: Replace export `ADD COLUMN`s with `DROP COLUMN`s in `sql/14_rollup_optimization.sql`**

In the `ALTER TABLE lakets._rollup_registry` block (the M23–M28 one), remove these four lines:
```sql
    ADD COLUMN IF NOT EXISTS export_enabled      BOOLEAN DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS export_delta_table  TEXT,
    ADD COLUMN IF NOT EXISTS export_mode         TEXT    DEFAULT 'incremental',
    ADD COLUMN IF NOT EXISTS last_exported_at    TIMESTAMPTZ;
```
(Keep the `ADD COLUMN`s above them intact; ensure the now-last retained `ADD COLUMN` line ends with `;`.) Then add a migration drop immediately after that `ALTER`:
```sql
-- Path B removal: drop legacy RollUp→UC export columns (superseded by CDF sync)
ALTER TABLE lakets._rollup_registry
    DROP COLUMN IF EXISTS export_enabled,
    DROP COLUMN IF EXISTS export_delta_table,
    DROP COLUMN IF EXISTS export_mode,
    DROP COLUMN IF EXISTS last_exported_at;
```

- [ ] **Step 3: Delete the export functions in `sql/14_rollup_optimization.sql`**

Delete the entire `MODULE 28: RollUp Export Pipeline` section — the
`enable_rollup_export`, `disable_rollup_export`, and `show_rollup_exports` function
definitions (and their banner comment).

- [ ] **Step 4: Verify build + reinstall succeeds and export columns are gone**

Run: `make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql`
Expected: build succeeds (no missing-module error), reinstall succeeds, and TEST 2's
`export_enabled` assertion now PASSES (count 0). Full `tests/test_rollup_sync.sql` ends
with `ALL ROLLUP SYNC TESTS PASSED`.

- [ ] **Step 5: Confirm no dangling references**

Run: `grep -rn "enable_rollup_export\|disable_rollup_export\|show_rollup_exports\|export_enabled\|export_delta_table\|_uc_integration\|register_uc_table\|tag_uc_table" sql/`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add -A sql/ tests/ build.sh
git commit -m "refactor(uc): remove Path B RollUp export + UC registration SQL"
```

---

## Task 5: Remove Path B Python jobs + update remaining tests

**Files:**
- Delete: `databricks/workflows/rollup_export.py`, `databricks/workflows/uc_registration.py`
- Modify: `tests/test_rollup_optimization.sql`, `tests/test_security_hardening.sql` (remove export blocks)
- Modify: `tests/test_shadow_sync.sql` (shadows now in `lakets_cdf`; true-mirror)

- [ ] **Step 1: Delete the Python jobs**

```bash
git rm databricks/workflows/rollup_export.py databricks/workflows/uc_registration.py
```
Confirm no bundle/job references remain:
Run: `grep -rn "rollup_export\|uc_registration" databricks/`
Expected: no matches (the bundle `databricks.yml` has no jobs for these). If any console-script/entry-point definition references them, remove it.

- [ ] **Step 2: Remove export blocks from `tests/test_rollup_optimization.sql`**

Run: `grep -n "export_enabled\|enable_rollup_export\|export_delta_table\|export_mode" tests/test_rollup_optimization.sql`
Delete the test blocks that reference these (the export-pipeline tests). Keep all other
optimization tests intact.

- [ ] **Step 3: Remove export references from `tests/test_security_hardening.sql`**

Run: `grep -n "export\|uc_registr\|register_uc\|tag_uc" tests/test_security_hardening.sql`
Delete only the blocks asserting on the removed export/UC functions; keep the rest.

- [ ] **Step 4: Update `tests/test_shadow_sync.sql` for `lakets_cdf` + true mirror**

Change the shadow-existence and replica-identity assertions from schema `'public'` to
`'lakets_cdf'`:
```sql
        WHERE table_schema = 'lakets_cdf' AND table_name = '_shadow_sync_test'
```
and
```sql
    WHERE n.nspname = 'lakets_cdf' AND c.relname = '_shadow_sync_test';
```
Change Test 3's forwarded-row count source:
```sql
    SELECT count(*) INTO v_count FROM lakets_cdf._shadow_sync_test;
```
Add a delete-mirror assertion after Test 3 (renumber the existing Test 4/5 if desired):
```sql
-- Test 3b: source DELETE removes the row from the shadow (true mirror)
DO $$
DECLARE v_n BIGINT;
BEGIN
    DELETE FROM sync_test WHERE sensor = 'test_3a';
    SELECT count(*) INTO v_n FROM lakets_cdf._shadow_sync_test WHERE sensor = 'test_3a';
    ASSERT v_n = 0, format('TEST 3b FAILED: delete not mirrored (%s)', v_n);
    RAISE NOTICE 'TEST 3b PASSED: delete mirrored';
END $$;
```

- [ ] **Step 5: Run the affected test suites**

Run:
```bash
make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql
psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_shadow_sync.sql
psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_sync.sql
psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_rollup_optimization.sql
psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_security_hardening.sql
```
Expected: each ends with its `ALL ... PASSED` summary; no errors.

- [ ] **Step 6: Commit**

```bash
git add -A databricks/ tests/
git commit -m "refactor(uc): remove Path B Python jobs and export test coverage"
```

---

## Task 6: Documentation

**Files:**
- Rewrite: `website/docs/how-to/export-to-uc.md`
- Delete: `website/docs/reference/unity-catalog.md`; fold into `website/docs/reference/lakebase-cdf.md`
- Modify: `website/docs/glossary.md`, `guides/how-it-works/rollups.md`, `reference/rollups.md`, `reference/metadata-tables.md`

- [ ] **Step 1: Rewrite `website/docs/how-to/export-to-uc.md`**

Replace the file contents with (keep the front-matter `sidebar_position`, retitle):

```markdown
---
title: Sync RollUps to Unity Catalog
sidebar_label: Sync to Unity Catalog
sidebar_position: 2
description: Make RollUp Tables available to Spark, ML, and BI by syncing them to Unity Catalog via Lakebase CDF.
---

# Sync RollUps to Unity Catalog (via Lakebase CDF)

RollUp Tables live in Lakebase. To make them visible to Spark, BI, and ML, sync them
to Unity Catalog with **Lakebase CDF** — the same mechanism ChronoTables use.

## Enable sync

```sql
SELECT lakets.enable_sync('metrics_hourly');
```

This sets `REPLICA IDENTITY FULL` on a shadow of the RollUp in the dedicated
`lakets_cdf` schema and installs a trigger that mirrors every change. CDF (enabled on
the `lakets_cdf` schema) replicates the shadow to a Unity Catalog Managed Table named
`lb__shadow_rollup_metrics_hourly_history`.

> **Why a shadow / `lakets_cdf`?** Lakebase CDF does not support partitioned tables and
> fails on any schema that contains them. ChronoTable parents are partitioned and live
> in `public`, so all synced tables are mirrored into the partition-free `lakets_cdf`
> schema instead. This layer is a workaround for the current limitation and can be
> removed once Lakebase supports partitioned-table CDF.

## Disable sync

```sql
SELECT lakets.disable_sync('metrics_hourly');
```

## Notes

- RollUp sync assumes incremental refresh (`DELETE + INSERT`), which CDC captures as
  row-level changes. The UC destination is an append-only change feed.
- Calling `enable_sync` / `disable_sync` twice is a no-op.
```

- [ ] **Step 2: Fold UC reference into the CDF reference and delete the standalone**

```bash
git rm website/docs/reference/unity-catalog.md
```
In `website/docs/reference/lakebase-cdf.md`, add a short section documenting that
`enable_sync(name)` / `disable_sync(name)` accept both ChronoTables and RollUps,
shadows live in `lakets_cdf`, and the UC destination is `lb_<shadow>_history`.

- [ ] **Step 3: Fix Path B mentions**

Run: `grep -rn "enable_rollup_export\|disable_rollup_export\|show_rollup_exports\|rollup_export.py\|uc_registration\|register_uc_table\|export-to-uc\|unity-catalog" website/docs/`
For each hit in `glossary.md`, `guides/how-it-works/rollups.md`, `reference/rollups.md`,
`reference/metadata-tables.md`, and `sidebars.ts` if present: replace export-API
references with `enable_sync`/CDF wording, and update the `unity-catalog` doc link to the
CDF reference. Remove the "Cold export via rollup_export.py" rows/paragraphs.

- [ ] **Step 4: Build the docs**

Run: `cd website && npm run build`
Expected: build succeeds with no broken-link errors (Docusaurus fails the build on
broken internal links — fix any that reference the removed `unity-catalog` page).

- [ ] **Step 5: Commit**

```bash
git add -A website/
git commit -m "docs(uc): document RollUp CDF sync; remove Path B export docs"
```

---

## Task 7: CHANGELOG / README + final verification

**Files:**
- Modify: `CHANGELOG.md`, `README.md`

- [ ] **Step 1: Update CHANGELOG and README**

Run: `grep -n "rollup_export\|uc_registration\|enable_rollup_export\|15_uc_integration\|register_uc_table" CHANGELOG.md README.md`
In `README.md`, change the `ROLLUP -->|"rollup_export.py"| COLD` reference to describe
CDF sync (`enable_sync`). In `CHANGELOG.md`, add an entry under the current unreleased
version:
```markdown
### Changed
- RollUps now sync to Unity Catalog via Lakebase CDF (`enable_sync`), replacing the
  custom export pipeline. Synced tables are mirrored into the new `lakets_cdf` schema.

### Removed
- `enable_rollup_export` / `disable_rollup_export` / `show_rollup_exports`,
  `sql/15_uc_integration.sql` and its functions, and the `rollup_export.py` /
  `uc_registration.py` Databricks jobs.
```

- [ ] **Step 2: Full verification**

Run:
```bash
make build && psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f dist/lakets.sql
for t in tests/test_*.sql; do echo "== $t =="; psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f "$t" || exit 1; done
cd website && npm run build && cd ..
grep -rn "rollup_export\|uc_registration\|enable_rollup_export\|_uc_registry\|15_uc_integration" sql/ databricks/ tests/ website/docs/ README.md || echo "no dangling Path B references"
```
Expected: clean install, all test suites pass, docs build, and no dangling references.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs(uc): update CHANGELOG and README for CDF-based RollUp sync"
```

---

## Self-Review checklist (run after drafting; already applied)

- **Spec coverage:** schema isolation (Task 1), generalized `enable_sync` + dispatch +
  idempotency (Task 2), true-mirror trigger (Task 2), ChronoTable shadow relocation
  (Task 2 + Task 5 test update), `drop_rollup` teardown (Task 3), registry changes
  (Task 1 + Task 4), Path B removal SQL/Python/tests/docs (Tasks 4–6),
  CHANGELOG/README + build checks (Task 7). `refresh_mode` removal intentionally absent
  (out of scope).
- **Placeholders:** none — every code/test step contains full content; the only
  conditional steps (grants, entry-point cleanup) include the exact command to discover
  whether they apply.
- **Type/name consistency:** shadow names `_shadow_<table>` (ChronoTable) and
  `_shadow_rollup_<name>` (RollUp); functions `_build_shadow_table`,
  `_enable_chronotable_sync`, `_enable_rollup_sync`, `_disable_chronotable_sync`,
  `_disable_rollup_sync` are defined in Task 2 and reused consistently in Task 3.
```
