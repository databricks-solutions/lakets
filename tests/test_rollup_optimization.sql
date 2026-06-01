-- =============================================================================
-- LakeTS RollUp Optimization Tests (Modules 23–28)
-- Requires: 99_install.sql applied (including 13_rollup_optimization.sql)
-- =============================================================================

-- Cleanup from previous runs
DROP VIEW IF EXISTS public._rollup_rt_opt_1min;
DROP VIEW IF EXISTS public._rollup_rt_opt_1hour;
DROP VIEW IF EXISTS public._rollup_rt_opt_1day;
DROP TABLE IF EXISTS public._rollup_opt_1min;
DROP TABLE IF EXISTS public._rollup_opt_1hour;
DROP TABLE IF EXISTS public._rollup_opt_1day;
DELETE FROM lakets._rollup_invalidation_log WHERE rollup_id IN (
    SELECT id FROM lakets._rollup_registry WHERE name IN ('opt_1min', 'opt_1hour', 'opt_1day')
);
DELETE FROM lakets._rollup_registry WHERE name IN ('opt_1min', 'opt_1hour', 'opt_1day');
DROP TABLE IF EXISTS public.opt_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'opt_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'opt_test';

-- Create test ChronoTable with 7 days of data
CREATE TABLE public.opt_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
INSERT INTO opt_test (time, val)
SELECT ts, (extract(epoch FROM ts) % 100)::DOUBLE PRECISION
FROM generate_series(
    now() - INTERVAL '7 days',
    now() - INTERVAL '1 hour',
    '5 minutes'
) ts;
SELECT lakets.create_chronotable('opt_test', 'time', '1 day');


-- ═══════════════════════════════════════════════════════════════════════════
-- T13: _detect_bucket_column returns the correct column name
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; BEGIN
    SELECT lakets._detect_bucket_column(
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt FROM opt_test GROUP BY 1$q$
    ) INTO v;
    ASSERT v = 'bucket', format('expected bucket, got %s', v);
    RAISE NOTICE 'T13 PASSED: _detect_bucket_column returns %', v;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T14: _get_dirty_chunks returns only modified chunks
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_ct_id INT; v_count INT; v_total INT; BEGIN
    SELECT id INTO v_ct_id FROM lakets._chronotable_registry WHERE table_name = 'opt_test';

    -- Mark one chunk as recently modified (use ctid subquery for PG LIMIT)
    UPDATE lakets._chunk_metadata
    SET last_modified_at = now()
    WHERE ctid = (
        SELECT ctid FROM lakets._chunk_metadata
        WHERE chronotable_id = v_ct_id AND status = 'active'
        LIMIT 1
    );

    SELECT count(*) INTO v_total FROM lakets._chunk_metadata
    WHERE chronotable_id = v_ct_id AND status = 'active';

    SELECT count(*) INTO v_count FROM lakets._get_dirty_chunks(v_ct_id, now() - INTERVAL '1 minute');
    ASSERT v_count >= 1, 'expected at least 1 dirty chunk';
    -- Chunks without last_modified_at are also returned (conservative)
    RAISE NOTICE 'T14 PASSED: _get_dirty_chunks returned % of % chunks', v_count, v_total;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T15: _inject_time_predicate adds WHERE clause to simple query
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; BEGIN
    SELECT lakets._inject_time_predicate(
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt FROM opt_test GROUP BY 1$q$,
        'time',
        now() - INTERVAL '1 day'
    ) INTO v;
    ASSERT v ~* 'WHERE.*time', format('expected WHERE time clause, got: %s', left(v, 200));
    RAISE NOTICE 'T15 PASSED: _inject_time_predicate added WHERE clause';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T16: _inject_time_predicate falls back on invalid query
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; v_original TEXT; BEGIN
    v_original := 'INVALID SQL QUERY THAT WILL FAIL';
    SELECT lakets._inject_time_predicate(v_original, 'time', now()) INTO v;
    -- Should return original since EXPLAIN will fail
    ASSERT v = v_original, 'expected fallback to original query';
    RAISE NOTICE 'T16 PASSED: _inject_time_predicate falls back on invalid query';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T17: _refresh_buckets_batch processes dirty buckets in 2 statements
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_id INT;
    v_refreshed INT;
    v_count_before BIGINT;
    v_count_after BIGINT;
BEGIN
    -- Create a RollUp for testing batch refresh
    SELECT lakets.create_rollup(
        'opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt,
                 round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        '1 hour',
        'opt_test'
    ) INTO v_id;

    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'opt_1min';

    SELECT count(*) INTO v_count_before FROM public._rollup_opt_1min;

    -- Manually create dirty bucket entries for historical buckets
    INSERT INTO lakets._rollup_invalidation_log (rollup_id, bucket_start, tier)
    VALUES
        (v_id, now() - INTERVAL '5 days', 'hot'),
        (v_id, now() - INTERVAL '4 days', 'hot'),
        (v_id, now() - INTERVAL '3 days', 'hot');

    -- Call batch refresh directly
    SELECT lakets._refresh_buckets_batch(
        v_id, '_rollup_opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt,
                 round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        'bucket',
        ARRAY[now() - INTERVAL '5 days', now() - INTERVAL '4 days', now() - INTERVAL '3 days']::timestamptz[]
    ) INTO v_refreshed;

    ASSERT v_refreshed = 3, format('expected 3 buckets refreshed, got %s', v_refreshed);

    SELECT count(*) INTO v_count_after FROM public._rollup_opt_1min;
    ASSERT v_count_after > 0, 'RollUp table is empty after batch refresh';
    RAISE NOTICE 'T17 PASSED: _refresh_buckets_batch refreshed % buckets (% rows)', v_refreshed, v_count_after;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T18: _refresh_buckets_chunked handles chunking
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_id INT;
    v_refreshed INT;
    v_buckets TIMESTAMPTZ[];
BEGIN
    SELECT id INTO v_id FROM lakets._rollup_registry WHERE name = 'opt_1min';

    -- Generate 5 dirty buckets
    SELECT array_agg(ts) INTO v_buckets
    FROM generate_series(now() - INTERVAL '6 days', now() - INTERVAL '2 days', '1 day') ts;

    SELECT lakets._refresh_buckets_chunked(
        v_id, '_rollup_opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt,
                 round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        'bucket', v_buckets, 2  -- chunk_size = 2 to force chunking
    ) INTO v_refreshed;

    ASSERT v_refreshed = array_length(v_buckets, 1),
        format('expected %s buckets, got %s', array_length(v_buckets, 1), v_refreshed);
    RAISE NOTICE 'T18 PASSED: _refresh_buckets_chunked handled % buckets with chunk_size=2', v_refreshed;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T19: create_rollup with depends_on stores dependencies
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_id INT; v_deps INT[]; BEGIN
    SELECT lakets.create_rollup(
        'opt_1hour',
        $q$SELECT lakets.time_bucket('1 day'::interval, bucket) AS bucket,
                 sum(cnt) AS cnt,
                 round(avg(avg_val)::numeric, 2) AS avg_val
          FROM _rollup_opt_1min GROUP BY 1$q$,
        '1 day',
        'opt_test',
        'public',
        ARRAY['opt_1min']  -- depends on opt_1min
    ) INTO v_id;

    SELECT depends_on INTO v_deps FROM lakets._rollup_registry WHERE name = 'opt_1hour';
    ASSERT array_length(v_deps, 1) = 1, format('expected 1 dependency, got %s', array_length(v_deps, 1));
    RAISE NOTICE 'T19 PASSED: create_rollup stored depends_on = %', v_deps;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T20: _build_rollup_dag returns correct topological order
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_dag INT[];
    v_first_name TEXT;
    v_second_name TEXT;
BEGIN
    v_dag := lakets._build_rollup_dag(NULL);
    ASSERT array_length(v_dag, 1) >= 2, 'DAG should have at least 2 nodes';

    -- opt_1min should come before opt_1hour in the DAG
    SELECT name INTO v_first_name FROM lakets._rollup_registry WHERE id = v_dag[1];
    -- Find where opt_1min and opt_1hour appear
    DECLARE
        v_pos_min INT;
        v_pos_hour INT;
        v_min_id INT;
        v_hour_id INT;
    BEGIN
        SELECT id INTO v_min_id FROM lakets._rollup_registry WHERE name = 'opt_1min';
        SELECT id INTO v_hour_id FROM lakets._rollup_registry WHERE name = 'opt_1hour';
        v_pos_min := array_position(v_dag, v_min_id);
        v_pos_hour := array_position(v_dag, v_hour_id);
        ASSERT v_pos_min < v_pos_hour,
            format('opt_1min (pos %s) should come before opt_1hour (pos %s)', v_pos_min, v_pos_hour);
    END;

    RAISE NOTICE 'T20 PASSED: _build_rollup_dag returns correct order: %', v_dag;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T21: _build_rollup_dag detects cycles
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_min_id INT;
    v_hour_id INT;
BEGIN
    SELECT id INTO v_min_id FROM lakets._rollup_registry WHERE name = 'opt_1min';
    SELECT id INTO v_hour_id FROM lakets._rollup_registry WHERE name = 'opt_1hour';

    -- Temporarily create a cycle: opt_1min depends on opt_1hour
    -- (disable validation trigger temporarily)
    ALTER TABLE lakets._rollup_registry DISABLE TRIGGER trg_validate_rollup_deps;
    UPDATE lakets._rollup_registry SET depends_on = ARRAY[v_hour_id] WHERE id = v_min_id;
    ALTER TABLE lakets._rollup_registry ENABLE TRIGGER trg_validate_rollup_deps;

    BEGIN
        PERFORM lakets._build_rollup_dag(NULL);
        ASSERT FALSE, 'expected exception for circular dependency';
    EXCEPTION WHEN OTHERS THEN
        ASSERT SQLERRM ~* 'circular', format('expected circular error, got: %s', SQLERRM);
    END;

    -- Restore: remove the artificial cycle
    ALTER TABLE lakets._rollup_registry DISABLE TRIGGER trg_validate_rollup_deps;
    UPDATE lakets._rollup_registry SET depends_on = '{}' WHERE id = v_min_id;
    ALTER TABLE lakets._rollup_registry ENABLE TRIGGER trg_validate_rollup_deps;

    RAISE NOTICE 'T21 PASSED: _build_rollup_dag detects cycles';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T22: refresh_rollup_cascade refreshes in dependency order
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; v_first TEXT; BEGIN
    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds'
    WHERE name IN ('opt_1min', 'opt_1hour');

    SELECT count(*) INTO v_count FROM lakets.refresh_rollup_cascade('opt_1hour');
    ASSERT v_count >= 2, format('expected at least 2 refreshes, got %s', v_count);

    -- Verify opt_1min was refreshed first
    SELECT rollup_name INTO v_first FROM lakets.refresh_rollup_cascade('opt_1hour') LIMIT 1;
    ASSERT v_first = 'opt_1min', format('expected opt_1min first, got %s', v_first);
    RAISE NOTICE 'T22 PASSED: refresh_rollup_cascade refreshed % RollUps in order', v_count;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T23: _resolve_bucket_tier returns correct tier
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_ct_id INT; v_tier TEXT; BEGIN
    SELECT id INTO v_ct_id FROM lakets._chronotable_registry WHERE table_name = 'opt_test';

    -- Active chunks should return 'hot'
    SELECT lakets._resolve_bucket_tier(v_ct_id, now() - INTERVAL '2 days') INTO v_tier;
    ASSERT COALESCE(v_tier, 'hot') = 'hot', format('expected hot, got %s', v_tier);

    RAISE NOTICE 'T23 PASSED: _resolve_bucket_tier returns %', COALESCE(v_tier, 'hot (default)');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T24: invalidate_rollup_range auto-detects tier when NULL
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; v_tier TEXT; BEGIN
    -- Call with p_tier = NULL (auto-detect)
    SELECT lakets.invalidate_rollup_range(
        'opt_1min', now() - INTERVAL '3 days', now() - INTERVAL '2 days', NULL
    ) INTO v_count;
    ASSERT v_count > 0, 'invalidate_rollup_range returned 0';

    -- Check that entries were created with auto-detected tier
    SELECT DISTINCT tier INTO v_tier
    FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'opt_1min')
    LIMIT 1;
    ASSERT v_tier IS NOT NULL, 'no tier detected';
    RAISE NOTICE 'T24 PASSED: invalidate_rollup_range auto-detected tier=% for % entries', v_tier, v_count;

    -- Cleanup
    DELETE FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'opt_1min');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T25: Bulk INSERT fires statement-level trigger + creates invalidation entries
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; BEGIN
    -- Enable invalidation (installs both per-row and statement-level triggers)
    PERFORM lakets.enable_rollup_invalidation('opt_1min');
    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'opt_1min';

    -- Refresh to clear any existing entries and set watermark
    PERFORM lakets.refresh_rollup('opt_1min');

    -- Bulk insert historical data (below watermark)
    INSERT INTO opt_test (time, val)
    SELECT ts, 99.0
    FROM generate_series(
        now() - INTERVAL '5 days',
        now() - INTERVAL '5 days' + INTERVAL '1 hour',
        '10 minutes'
    ) ts;

    -- Check invalidation log has entries from the statement-level trigger
    SELECT count(*) INTO v_count
    FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'opt_1min');

    ASSERT v_count > 0, 'expected invalidation entries from bulk INSERT';
    RAISE NOTICE 'T25 PASSED: bulk INSERT created % invalidation entries', v_count;

    -- Cleanup
    PERFORM lakets.disable_rollup_invalidation('opt_1min');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T27: Updated refresh_rollup uses batch refresh for Phase 2
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_result BOOLEAN; v_remaining INT; BEGIN
    UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'opt_1min';

    -- Create some hot-tier invalidation entries
    PERFORM lakets.invalidate_rollup_range('opt_1min', now() - INTERVAL '6 days', now() - INTERVAL '4 days', 'hot');

    SELECT count(*) INTO v_remaining FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'opt_1min')
      AND tier = 'hot';
    ASSERT v_remaining > 0, 'expected invalidation entries before refresh';

    -- Refresh should process them via batch (M24)
    SELECT lakets.refresh_rollup('opt_1min') INTO v_result;
    ASSERT v_result = TRUE, 'refresh_rollup should return TRUE';

    SELECT count(*) INTO v_remaining FROM lakets._rollup_invalidation_log
    WHERE rollup_id = (SELECT id FROM lakets._rollup_registry WHERE name = 'opt_1min')
      AND tier = 'hot';
    ASSERT v_remaining = 0, format('expected 0 entries after refresh, got %s', v_remaining);

    RAISE NOTICE 'T27 PASSED: refresh_rollup batch-processed invalidation entries';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T28: show_rollup_dag displays correct structure
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_count INT; BEGIN
    SELECT count(*) INTO v_count FROM lakets.show_rollup_dag();
    ASSERT v_count >= 2, format('expected at least 2 DAG entries, got %s', v_count);
    RAISE NOTICE 'T28 PASSED: show_rollup_dag returned % entries', v_count;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T29: _refresh_buckets_batch returns 0 for NULL/empty array
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_id INT; v_refreshed INT; BEGIN
    SELECT id INTO v_id FROM lakets._rollup_registry WHERE name = 'opt_1min';

    SELECT lakets._refresh_buckets_batch(v_id, '_rollup_opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt, round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        'bucket', NULL
    ) INTO v_refreshed;
    ASSERT v_refreshed = 0, format('expected 0, got %s', v_refreshed);

    SELECT lakets._refresh_buckets_batch(v_id, '_rollup_opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt, round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        'bucket', '{}'::timestamptz[]
    ) INTO v_refreshed;
    ASSERT v_refreshed = 0, format('expected 0, got %s', v_refreshed);

    RAISE NOTICE 'T29 PASSED: _refresh_buckets_batch returns 0 for empty input';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T30: _detect_bucket_column falls back to 'bucket' on invalid query
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; BEGIN
    SELECT lakets._detect_bucket_column('THIS IS NOT VALID SQL') INTO v;
    ASSERT v = 'bucket', format('expected fallback to bucket, got %s', v);
    RAISE NOTICE 'T30 PASSED: _detect_bucket_column falls back to bucket on invalid SQL';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T31: _validate_rollup_dependencies rejects self-dependency
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_id INT; BEGIN
    SELECT id INTO v_id FROM lakets._rollup_registry WHERE name = 'opt_1min';
    BEGIN
        UPDATE lakets._rollup_registry SET depends_on = ARRAY[v_id] WHERE id = v_id;
        ASSERT FALSE, 'expected exception for self-dependency';
    EXCEPTION WHEN OTHERS THEN
        ASSERT SQLERRM ~* 'itself', format('expected "itself" error, got: %s', SQLERRM);
    END;
    RAISE NOTICE 'T31 PASSED: self-dependency rejected';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T32: _validate_rollup_dependencies rejects nonexistent dependency
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_id INT; BEGIN
    SELECT id INTO v_id FROM lakets._rollup_registry WHERE name = 'opt_1min';
    BEGIN
        UPDATE lakets._rollup_registry SET depends_on = ARRAY[99999] WHERE id = v_id;
        ASSERT FALSE, 'expected exception for nonexistent dependency';
    EXCEPTION WHEN OTHERS THEN
        ASSERT SQLERRM ~* 'does not exist', format('expected "does not exist" error, got: %s', SQLERRM);
    END;
    RAISE NOTICE 'T32 PASSED: nonexistent dependency rejected';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T34: _refresh_buckets_chunked returns 0 for empty input
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v_id INT; v_refreshed INT; BEGIN
    SELECT id INTO v_id FROM lakets._rollup_registry WHERE name = 'opt_1min';

    SELECT lakets._refresh_buckets_chunked(v_id, '_rollup_opt_1min',
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt, round(avg(val)::numeric, 2) AS avg_val
          FROM opt_test GROUP BY 1$q$,
        'bucket', '{}'::timestamptz[], 2
    ) INTO v_refreshed;
    ASSERT v_refreshed = 0, format('expected 0, got %s', v_refreshed);
    RAISE NOTICE 'T34 PASSED: _refresh_buckets_chunked returns 0 for empty input';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T35: _inject_time_predicate with existing WHERE clause
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; BEGIN
    SELECT lakets._inject_time_predicate(
        $q$SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket,
                 count(*) AS cnt FROM opt_test WHERE val > 10 GROUP BY 1$q$,
        'time',
        now() - INTERVAL '1 day'
    ) INTO v;
    ASSERT v ~* 'WHERE.*time.*AND.*val', format('expected WHERE time AND val, got: %s', left(v, 200));
    RAISE NOTICE 'T35 PASSED: _inject_time_predicate with existing WHERE clause';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T36: _inject_time_predicate with NULL time_column returns original
-- ═══════════════════════════════════════════════════════════════════════════
DO $$ DECLARE v TEXT; v_orig TEXT; BEGIN
    v_orig := 'SELECT 1 FROM opt_test';
    SELECT lakets._inject_time_predicate(v_orig, NULL, now()) INTO v;
    ASSERT v = v_orig, 'expected original query returned for NULL time_column';
    RAISE NOTICE 'T36 PASSED: NULL time_column returns original query';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- T37: Multi-level DAG — 3-level chain (1min → 1hour → 1day)
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
    v_id_day INT;
    v_dag INT[];
    v_min_id INT;
    v_hour_id INT;
    v_day_id INT;
    v_pos_min INT;
    v_pos_hour INT;
    v_pos_day INT;
BEGIN
    -- Create a 3rd level: opt_1day depends on opt_1hour
    SELECT lakets.create_rollup(
        'opt_1day',
        $q$SELECT lakets.time_bucket('7 days'::interval, bucket) AS bucket,
                 sum(cnt) AS cnt, round(avg(avg_val)::numeric, 2) AS avg_val
          FROM _rollup_opt_1hour GROUP BY 1$q$,
        '7 days',
        'opt_test',
        'public',
        ARRAY['opt_1hour']
    ) INTO v_id_day;

    v_dag := lakets._build_rollup_dag(ARRAY[v_id_day]);

    SELECT id INTO v_min_id FROM lakets._rollup_registry WHERE name = 'opt_1min';
    SELECT id INTO v_hour_id FROM lakets._rollup_registry WHERE name = 'opt_1hour';
    v_day_id := v_id_day;

    v_pos_min := array_position(v_dag, v_min_id);
    v_pos_hour := array_position(v_dag, v_hour_id);
    v_pos_day := array_position(v_dag, v_day_id);

    ASSERT v_pos_min < v_pos_hour, format('min(pos %s) should < hour(pos %s)', v_pos_min, v_pos_hour);
    ASSERT v_pos_hour < v_pos_day, format('hour(pos %s) should < day(pos %s)', v_pos_hour, v_pos_day);

    RAISE NOTICE 'T37 PASSED: 3-level DAG order: min(%)→hour(%)→day(%)', v_pos_min, v_pos_hour, v_pos_day;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Cleanup
-- ═══════════════════════════════════════════════════════════════════════════
DROP VIEW IF EXISTS public._rollup_rt_opt_1day;
DROP VIEW IF EXISTS public._rollup_rt_opt_1hour;
DROP VIEW IF EXISTS public._rollup_rt_opt_1min;
DROP TABLE IF EXISTS public._rollup_opt_1day;
DROP TABLE IF EXISTS public._rollup_opt_1hour;
DROP TABLE IF EXISTS public._rollup_opt_1min;
DELETE FROM lakets._rollup_invalidation_log WHERE rollup_id IN (
    SELECT id FROM lakets._rollup_registry WHERE name IN ('opt_1min', 'opt_1hour', 'opt_1day')
);
DELETE FROM lakets._rollup_registry WHERE name IN ('opt_1min', 'opt_1hour', 'opt_1day');
DROP TABLE IF EXISTS public.opt_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'opt_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'opt_test';

SELECT '=== ALL ROLLUP OPTIMIZATION TESTS PASSED ===' AS result;
