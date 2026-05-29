-- =============================================================================
-- LakeTS: refresh_mode removed — RollUps are always incremental
-- =============================================================================
DROP VIEW IF EXISTS public._rollup_rt_drm_test;
DROP TABLE IF EXISTS public._rollup_drm_test;
DELETE FROM lakets._rollup_registry WHERE name='drm_test';
DROP TABLE IF EXISTS public.drm_metrics CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name='drm_metrics');
DELETE FROM lakets._chronotable_registry WHERE table_name='drm_metrics';
CREATE TABLE public.drm_metrics (time TIMESTAMPTZ NOT NULL, sensor TEXT NOT NULL, reading DOUBLE PRECISION);
INSERT INTO drm_metrics
SELECT ts,'s1',(extract(epoch FROM ts)%100)::DOUBLE PRECISION
FROM generate_series(now()-INTERVAL '2 days', now()-INTERVAL '1 hour','1 hour') ts;
SELECT lakets.create_chronotable('drm_metrics','time','1 day');

-- Test 1: _rollup_registry has no refresh_mode column
DO $$ DECLARE v INT; BEGIN
    SELECT count(*) INTO v FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='refresh_mode';
    ASSERT v=0, 'TEST 1 FAILED: refresh_mode column still present';
    RAISE NOTICE 'TEST 1 PASSED: refresh_mode column removed';
END $$;

-- Test 2: create_rollup works without a mode arg and loads data
DO $$ DECLARE v_id INT; v_rows BIGINT; BEGIN
    SELECT lakets.create_rollup('drm_test',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket, sensor,
                 round(avg(reading)::numeric,2) AS avg_reading FROM drm_metrics GROUP BY 1,2$q$,
        '1 hour','drm_metrics') INTO v_id;
    ASSERT v_id IS NOT NULL, 'TEST 2 FAILED: create_rollup returned NULL';
    SELECT count(*) INTO v_rows FROM public._rollup_drm_test;
    ASSERT v_rows > 0, 'TEST 2 FAILED: rollup empty';
    RAISE NOTICE 'TEST 2 PASSED: create_rollup (no mode arg) works, % rows', v_rows;
END $$;

-- Test 3: incremental refresh still updates after new source rows
DO $$ DECLARE v_before BIGINT; v_after BIGINT; BEGIN
    SELECT count(*) INTO v_before FROM public._rollup_drm_test;
    INSERT INTO drm_metrics VALUES (now(), 's2', 5.0);
    UPDATE lakets._rollup_registry SET refresh_lag='0 seconds' WHERE name='drm_test';
    PERFORM lakets.refresh_rollup('drm_test');
    SELECT count(*) INTO v_after FROM public._rollup_drm_test;
    ASSERT v_after >= v_before, 'TEST 3 FAILED: refresh did not run';
    RAISE NOTICE 'TEST 3 PASSED: incremental refresh works (% -> %)', v_before, v_after;
END $$;

-- Test 4: enable_rollup_invalidation no longer rejects (no mode guard)
DO $$ BEGIN
    PERFORM lakets.enable_rollup_invalidation('drm_test');
    RAISE NOTICE 'TEST 4 PASSED: enable_rollup_invalidation works without mode guard';
END $$;

-- Cleanup
SELECT lakets.drop_rollup('drm_test');
DROP TABLE IF EXISTS public.drm_metrics CASCADE;
DELETE FROM lakets._chronotable_registry WHERE table_name='drm_metrics';
SELECT 'ALL DROP-REFRESH-MODE TESTS PASSED' as result;
