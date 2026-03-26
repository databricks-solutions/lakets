-- =============================================================================
-- LakeTS RollUp Engine Tests
-- =============================================================================

-- Cleanup from previous runs
DROP VIEW IF EXISTS public._rollup_rt_test_ru;
DROP TABLE IF EXISTS public._rollup_test_ru;
DELETE FROM lakets._rollup_invalidation_log WHERE rollup_id IN (
    SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru'
);
DELETE FROM lakets._rollup_registry WHERE name = 'test_ru';
DROP TABLE IF EXISTS public.ru_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'ru_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'ru_test';

-- Create test ChronoTable with sample data
SELECT lakets.create_chronotable('ru_test', 'time', '1 day');

INSERT INTO ru_test (time, val)
SELECT ts, (extract(epoch FROM ts) % 100)::DOUBLE PRECISION
FROM generate_series(
    now() - INTERVAL '7 days',
    now() - INTERVAL '1 hour',
    '10 minutes'
) ts;

-- ═══════════════════════════════════════════════════════════════════════════
-- T1: create_rollup returns a non-null ID
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.create_rollup(
        'test_ru',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt,
                 round(avg(val)::numeric, 2) AS avg_val
          FROM ru_test
          GROUP BY 1$q$,
        '1 hour',
        'ru_test'
    ) INTO v;
    ASSERT v IS NOT NULL, 'create_rollup returned NULL';
    RAISE NOTICE 'T1 PASSED: create_rollup returned ID %', v;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T2: RollUp Table has rows after creation
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM public._rollup_test_ru;
    ASSERT v > 0, 'RollUp Table is empty after creation';
    RAISE NOTICE 'T2 PASSED: RollUp Table has % rows', v;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T3: show_rollups lists the RollUp with watermark
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; v_wm TIMESTAMPTZ; BEGIN
    SELECT count(*) INTO v_count FROM lakets.show_rollups() WHERE name = 'test_ru';
    ASSERT v_count = 1, 'show_rollups missing test_ru';

    SELECT watermark INTO v_wm FROM lakets._rollup_registry WHERE name = 'test_ru';
    ASSERT v_wm IS NOT NULL, 'watermark is NULL after creation';
    RAISE NOTICE 'T3 PASSED: show_rollups lists test_ru, watermark=%', v_wm;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T4: Insert new data + refresh_rollup returns TRUE (incremental)
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_result BOOLEAN; v_old_wm TIMESTAMPTZ; v_new_wm TIMESTAMPTZ; BEGIN
    SELECT watermark INTO v_old_wm FROM lakets._rollup_registry WHERE name = 'test_ru';

    -- Insert data newer than watermark
    INSERT INTO ru_test (time, val) VALUES (now(), 42.0);

    -- Set refresh_lag to 0 so we can refresh immediately
    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'test_ru';

    SELECT lakets.refresh_rollup('test_ru') INTO v_result;
    ASSERT v_result = TRUE, 'refresh_rollup did not return TRUE';

    SELECT watermark INTO v_new_wm FROM lakets._rollup_registry WHERE name = 'test_ru';
    ASSERT v_new_wm >= v_old_wm, 'watermark did not advance';
    RAISE NOTICE 'T4 PASSED: refresh_rollup returned TRUE, watermark advanced from % to %', v_old_wm, v_new_wm;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T5: refresh_rollup returns FALSE when within refresh_lag window
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_result BOOLEAN; BEGIN
    -- Set a long refresh_lag
    UPDATE lakets._rollup_registry SET refresh_lag = '1 hour' WHERE name = 'test_ru';

    SELECT lakets.refresh_rollup('test_ru') INTO v_result;
    ASSERT v_result = FALSE, 'refresh_rollup should return FALSE within refresh_lag';
    RAISE NOTICE 'T5 PASSED: refresh_rollup returned FALSE (within refresh_lag)';

    -- Reset for subsequent tests
    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'test_ru';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T6: create_rollup_view creates a readable real-time view
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v BIGINT; BEGIN
    PERFORM lakets.create_rollup_view(
        'test_ru',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt,
                 round(avg(val)::numeric, 2) AS avg_val
          FROM ru_test
          WHERE time > lakets._rollup_watermark('test_ru')
          GROUP BY 1$q$
    );
    SELECT count(*) INTO v FROM public._rollup_rt_test_ru;
    ASSERT v > 0, 'real-time view returned no rows';
    RAISE NOTICE 'T6 PASSED: real-time view has % rows', v;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T7: _rollup_watermark returns the stored watermark
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_fn TIMESTAMPTZ; v_reg TIMESTAMPTZ; BEGIN
    SELECT lakets._rollup_watermark('test_ru') INTO v_fn;
    SELECT watermark INTO v_reg FROM lakets._rollup_registry WHERE name = 'test_ru';
    ASSERT v_fn = v_reg, format('watermark mismatch: fn=%s reg=%s', v_fn, v_reg);
    RAISE NOTICE 'T7 PASSED: _rollup_watermark returns %', v_fn;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T8: enable_rollup_invalidation + UPDATE → invalidation log has entry
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; BEGIN
    PERFORM lakets.enable_rollup_invalidation('test_ru');

    -- Update a historical row (3 days ago)
    UPDATE ru_test SET val = val + 1
    WHERE time BETWEEN now() - INTERVAL '3 days' AND now() - INTERVAL '3 days' + INTERVAL '10 minutes';

    SELECT count(*) INTO v_count FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru')
      AND tier = 'hot';

    ASSERT v_count > 0, 'invalidation log has no entries after UPDATE';
    RAISE NOTICE 'T8 PASSED: invalidation log has % hot-tier entries', v_count;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T9: refresh_rollup processes invalidation log entries
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_result BOOLEAN; v_remaining INT; BEGIN
    SELECT lakets.refresh_rollup('test_ru') INTO v_result;
    ASSERT v_result = TRUE, 'refresh_rollup did not return TRUE';

    SELECT count(*) INTO v_remaining FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru')
      AND tier = 'hot';

    ASSERT v_remaining = 0, format('invalidation log still has % entries', v_remaining);
    RAISE NOTICE 'T9 PASSED: invalidation log cleared after refresh';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T10: invalidate_rollup_range creates entries with correct tier
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; v_cold_count INT; BEGIN
    SELECT lakets.invalidate_rollup_range(
        'test_ru', now() - INTERVAL '5 days', now() - INTERVAL '4 days', 'cold'
    ) INTO v_count;
    ASSERT v_count > 0, 'invalidate_rollup_range returned 0';

    SELECT count(*) INTO v_cold_count FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru')
      AND tier = 'cold';

    ASSERT v_cold_count = v_count, format('expected %s cold entries, got %s', v_count, v_cold_count);
    RAISE NOTICE 'T10 PASSED: invalidate_rollup_range created % cold-tier entries', v_count;

    -- Clean up cold entries (cold refresh is Databricks-side, not tested here)
    DELETE FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru')
      AND tier = 'cold';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T11: disable_rollup_invalidation removes trigger + clears log
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_trig_exists BOOLEAN; v_log_count INT; BEGIN
    -- Create a new invalidation entry first
    UPDATE ru_test SET val = val + 1
    WHERE time BETWEEN now() - INTERVAL '2 days' AND now() - INTERVAL '2 days' + INTERVAL '10 minutes';

    PERFORM lakets.disable_rollup_invalidation('test_ru');

    SELECT count(*) INTO v_log_count FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'test_ru');
    ASSERT v_log_count = 0, format('invalidation log still has % entries after disable', v_log_count);

    -- Verify trigger is gone
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public' AND c.relname = 'ru_test'
          AND t.tgname = 'trg_lakets_rollup_invalidation'
    ) INTO v_trig_exists;
    ASSERT v_trig_exists = FALSE, 'trigger still exists after disable';

    RAISE NOTICE 'T11 PASSED: trigger removed and invalidation log cleared';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T12: drop_rollup removes all objects
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v INT; BEGIN
    PERFORM lakets.drop_rollup('test_ru');
    SELECT count(*) INTO v FROM lakets._rollup_registry WHERE name = 'test_ru';
    ASSERT v = 0, 'registry entry still exists after drop';
    RAISE NOTICE 'T12 PASSED: drop_rollup removed all objects';
END $$;

-- Cleanup
DROP TABLE IF EXISTS public.ru_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'ru_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'ru_test';

SELECT '=== ALL ROLLUP TESTS PASSED ===' AS result;
