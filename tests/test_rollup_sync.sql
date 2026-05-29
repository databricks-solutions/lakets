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

-- Test 2: _rollup_registry has sync columns
DO $$
DECLARE v_sync INT; v_shadow INT;
BEGIN
    SELECT count(*) INTO v_sync FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='sync_enabled';
    SELECT count(*) INTO v_shadow FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='shadow_table_name';
    ASSERT v_sync = 1, 'TEST 2 FAILED: sync_enabled column missing';
    ASSERT v_shadow = 1, 'TEST 2 FAILED: shadow_table_name column missing';
    RAISE NOTICE 'TEST 2 PASSED: registry sync columns present';
END $$;

-- ---- Task 2 setup: a ChronoTable + an incremental RollUp ----
DROP VIEW IF EXISTS public._rollup_rt_rs_hourly;
DROP TABLE IF EXISTS public._rollup_rs_hourly;
DROP TABLE IF EXISTS lakets_cdf._shadow_rollup_rs_hourly;
DELETE FROM lakets._rollup_registry WHERE name = 'rs_hourly';
DROP TABLE IF EXISTS public.rs_metrics CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'rs_metrics');
DELETE FROM lakets._chronotable_registry WHERE table_name = 'rs_metrics';

CREATE TABLE public.rs_metrics (time TIMESTAMPTZ NOT NULL, sensor TEXT NOT NULL, reading DOUBLE PRECISION);
INSERT INTO rs_metrics (time, sensor, reading)
SELECT ts, 's1', (extract(epoch FROM ts) % 100)::DOUBLE PRECISION
FROM generate_series(now() - INTERVAL '2 days', now() - INTERVAL '1 hour', '1 hour') ts;
SELECT lakets.create_chronotable('rs_metrics', 'time', '1 day');

SELECT lakets.create_rollup(
    'rs_hourly',
    $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket, sensor,
             round(avg(reading)::numeric, 2) AS avg_reading
       FROM rs_metrics GROUP BY 1, 2$q$,
    '1 hour',
    'rs_metrics'
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
DO $$ BEGIN
    PERFORM lakets.enable_sync('rs_hourly');
    RAISE NOTICE 'TEST 4 PASSED: re-enable is idempotent';
END $$;

-- Test 5: source INSERT and DELETE mirror to the shadow (true mirror)
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
DO $$ BEGIN
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

-- ---- ChronoTable sync path + duplicate-row + UPDATE coverage ----
DROP TABLE IF EXISTS lakets_cdf._shadow_ct_sync_test;
DROP TABLE IF EXISTS public.ct_sync_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name='ct_sync_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ct_sync_test';
CREATE TABLE public.ct_sync_test (time TIMESTAMPTZ NOT NULL, sensor TEXT NOT NULL, reading DOUBLE PRECISION);
SELECT lakets.create_chronotable('ct_sync_test', 'time', '1 day');

-- Test 8: enable_sync on a ChronoTable creates shadow in lakets_cdf and forwards inserts
DO $$
DECLARE v_exists BOOLEAN; v_n BIGINT;
BEGIN
    PERFORM lakets.enable_sync('ct_sync_test');
    SELECT EXISTS(SELECT 1 FROM information_schema.tables
        WHERE table_schema='lakets_cdf' AND table_name='_shadow_ct_sync_test') INTO v_exists;
    ASSERT v_exists, 'TEST 8 FAILED: chronotable shadow not in lakets_cdf';
    INSERT INTO public.ct_sync_test VALUES (now(),'a',1.0),(now(),'b',2.0);
    SELECT count(*) INTO v_n FROM lakets_cdf._shadow_ct_sync_test;
    ASSERT v_n = 2, format('TEST 8 FAILED: shadow has %s rows', v_n);
    RAISE NOTICE 'TEST 8 PASSED: chronotable insert mirrored';
END $$;

-- Test 9: duplicate rows — deleting ONE source row deletes exactly ONE shadow row
DO $$
DECLARE v_ts TIMESTAMPTZ := now(); v_n BIGINT;
BEGIN
    INSERT INTO public.ct_sync_test VALUES (v_ts,'dup',5.0),(v_ts,'dup',5.0);
    SELECT count(*) INTO v_n FROM lakets_cdf._shadow_ct_sync_test WHERE sensor='dup';
    ASSERT v_n = 2, format('TEST 9 FAILED: setup expected 2 dup shadow rows, got %s', v_n);
    DELETE FROM public.ct_sync_test t
        WHERE t.ctid = (SELECT ctid FROM public.ct_sync_test WHERE sensor='dup' LIMIT 1);
    SELECT count(*) INTO v_n FROM lakets_cdf._shadow_ct_sync_test WHERE sensor='dup';
    ASSERT v_n = 1, format('TEST 9 FAILED: expected 1 dup shadow row after single delete, got %s', v_n);
    RAISE NOTICE 'TEST 9 PASSED: single-row delete mirrored (no over-delete)';
END $$;

-- Test 10: UPDATE mirrors (old value gone, new value present)
DO $$
DECLARE v_old BIGINT; v_new BIGINT;
BEGIN
    UPDATE public.ct_sync_test SET reading = 99.0 WHERE sensor='a';
    SELECT count(*) INTO v_old FROM lakets_cdf._shadow_ct_sync_test WHERE sensor='a' AND reading=1.0;
    SELECT count(*) INTO v_new FROM lakets_cdf._shadow_ct_sync_test WHERE sensor='a' AND reading=99.0;
    ASSERT v_old = 0, format('TEST 10 FAILED: old value still in shadow (%s)', v_old);
    ASSERT v_new = 1, format('TEST 10 FAILED: new value not in shadow (%s)', v_new);
    RAISE NOTICE 'TEST 10 PASSED: update mirrored';
END $$;

-- ChronoTable cleanup
SELECT lakets.disable_sync('ct_sync_test');
DROP TABLE IF EXISTS public.ct_sync_test CASCADE;
DELETE FROM lakets._chronotable_registry WHERE table_name='ct_sync_test';

SELECT 'ALL ROLLUP SYNC TESTS PASSED' as result;
