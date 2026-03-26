-- =============================================================================
-- LakeTS Multi-Metric ChronoTable Tests
-- =============================================================================
DROP TABLE IF EXISTS public.mt_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='mt_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='mt_test';

-- T1: Create metric table
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.create_metric_table('mt_test', ARRAY['host','region'], ARRAY['cpu','memory'], '1 day') INTO v;
    ASSERT v IS NOT NULL; RAISE NOTICE 'T1 PASSED: metric table id=%', v;
END $$;

-- T2: Insert and query
DO $$ DECLARE v BIGINT; BEGIN
    INSERT INTO mt_test SELECT now()-(i||' min')::interval, 'web-'||(i%5), 'us-'||(i%2), random()*100, random()*8192 FROM generate_series(1,500) s(i);
    SELECT count(*) INTO v FROM mt_test; ASSERT v = 500; RAISE NOTICE 'T2 PASSED: inserted %', v;
END $$;

-- T3: Composite index exists
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM pg_indexes WHERE tablename='mt_test' AND indexname LIKE '%series%';
    ASSERT v > 0; RAISE NOTICE 'T3 PASSED: series index exists';
END $$;

-- T4: BRIN index exists
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM pg_indexes WHERE tablename='mt_test' AND indexname LIKE '%brin%';
    ASSERT v > 0; RAISE NOTICE 'T4 PASSED: BRIN index exists';
END $$;

-- T5: cardinality_stats
DO $$ DECLARE v BIGINT; BEGIN
    SELECT distinct_values INTO v FROM lakets.cardinality_stats('mt_test') WHERE column_name='host';
    ASSERT v = 5; RAISE NOTICE 'T5 PASSED: host cardinality=%', v;
END $$;

-- T6: cardinality_check OK
DO $$ DECLARE v TEXT; BEGIN
    SELECT status INTO v FROM lakets.cardinality_check('mt_test', 100);
    ASSERT v = 'OK'; RAISE NOTICE 'T6 PASSED: cardinality status=%', v;
END $$;

-- T7: cardinality_check WARNING
DO $$ DECLARE v TEXT; BEGIN
    SELECT status INTO v FROM lakets.cardinality_check('mt_test', 12);
    ASSERT v = 'WARNING'; RAISE NOTICE 'T7 PASSED: cardinality warning at max=12';
END $$;

DROP TABLE IF EXISTS public.mt_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='mt_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='mt_test';
SELECT 'ALL METRIC TABLE TESTS PASSED' as result;
