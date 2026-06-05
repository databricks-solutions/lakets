-- =============================================================================
-- LakeTS Retention Tests
-- =============================================================================
DROP TABLE IF EXISTS public.ret_test CASCADE;
DELETE FROM lakets._policy_registry WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ret_test');
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ret_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ret_test';

CREATE TABLE public.ret_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
INSERT INTO ret_test SELECT now()-(i||' hours')::interval, random()*100 FROM generate_series(1,240) s(i);
SELECT lakets.create_chronotable('ret_test','time','1 day');

-- T1: Add retention policy
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.add_retention_policy('ret_test', '5 days') INTO v;
    ASSERT v IS NOT NULL; RAISE NOTICE 'T1 PASSED: policy id=%', v;
END $$;

-- T2: Show retention policy
DO $$ DECLARE v TEXT; BEGIN
    SELECT drop_after INTO v FROM lakets.show_retention_policy('ret_test');
    ASSERT v = '5 days'; RAISE NOTICE 'T2 PASSED: drop_after=%', v;
END $$;

-- T3: Execute retention
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.execute_retention('ret_test') INTO v;
    ASSERT v > 0; RAISE NOTICE 'T3 PASSED: dropped % chunks', v;
END $$;

-- T4: Remove and add tiered retention
DO $$ DECLARE v INT; BEGIN
    PERFORM lakets.remove_retention_policy('ret_test');
    SELECT lakets.add_tiered_retention_policy('ret_test', '3 days', '30 days') INTO v;
    ASSERT v IS NOT NULL; RAISE NOTICE 'T4 PASSED: tiered policy id=%', v;
END $$;

-- T5: Tiered validation (tier_after < drop_after)
DO $$ BEGIN
    BEGIN
        PERFORM lakets.add_tiered_retention_policy('ret_test', '30 days', '7 days');
        RAISE NOTICE 'T5 FAILED: should have raised exception';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'T5 PASSED: tier_after >= drop_after rejected';
    END;
END $$;

-- T6: Show tiered policy
DO $$ DECLARE vt TEXT; vd TEXT; BEGIN
    SELECT tier_after, drop_after INTO vt, vd FROM lakets.show_retention_policy('ret_test');
    ASSERT vt = '3 days' AND vd = '30 days'; RAISE NOTICE 'T6 PASSED: tier=%,drop=%', vt, vd;
END $$;

-- T7: On a CDF-synced table, retention defers un-validated chunks (fail-closed)
-- and p_force drops them anyway. Simulated with a synced-but-not-streaming shadow.
DO $$ DECLARE v_id INT; v_def INT; v_forced INT; BEGIN
    SELECT id INTO v_id FROM lakets._chronotable_registry WHERE table_name='ret_test';
    UPDATE lakets._chronotable_registry
    SET sync_enabled = TRUE, shadow_table_name = '_shadow_ret_test' WHERE id = v_id;
    -- An old active chunk past drop_after (30 days), stamped but not durable in UC.
    INSERT INTO lakets._chunk_metadata
        (chronotable_id, chunk_name, range_start, range_end, status, last_write_lsn)
    VALUES (v_id, 'public.ret_test_oldsync',
            now()-interval '40 days', now()-interval '39 days', 'active', pg_current_wal_lsn());

    -- Not streaming => cannot prove durable => deferred, nothing dropped.
    SELECT lakets.execute_retention('ret_test') INTO v_def;
    ASSERT v_def = 0, format('T7 FAILED: expected 0 (deferred), got %s', v_def);

    -- Force => drop the Lakebase partition regardless of UC validation.
    SELECT lakets.execute_retention('ret_test', 'public', TRUE) INTO v_forced;
    ASSERT v_forced >= 1, format('T7 FAILED: force should drop, got %s', v_forced);
    RAISE NOTICE 'T7 PASSED: synced retention defers un-validated; p_force drops';
END $$;

DROP TABLE IF EXISTS public.ret_test CASCADE;
DELETE FROM lakets._policy_registry WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ret_test');
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ret_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ret_test';
SELECT 'ALL RETENTION TESTS PASSED' as result;
