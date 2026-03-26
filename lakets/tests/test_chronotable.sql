-- =============================================================================
-- LakeTS ChronoTable Tests
-- =============================================================================

-- Setup
DROP TABLE IF EXISTS public.ct_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name = 'ct_test');
DELETE FROM lakets._chronotable_registry WHERE table_name = 'ct_test';

CREATE TABLE public.ct_test (time TIMESTAMPTZ NOT NULL, device_id TEXT NOT NULL, value DOUBLE PRECISION);
INSERT INTO public.ct_test SELECT now()-(i||' hours')::interval, 'dev_'||(i%3), random()*100 FROM generate_series(1,72) s(i);

-- T1: create_chronotable (V2 alias)
DO $$ DECLARE v_id INT; BEGIN
    SELECT lakets.create_chronotable('ct_test', 'time', '1 day') INTO v_id;
    ASSERT v_id IS NOT NULL, 'T1 FAILED'; RAISE NOTICE 'T1 PASSED: create_chronotable id=%', v_id;
END $$;

-- T2: Row count preserved
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM ct_test; ASSERT v = 72, format('T2 FAILED: %s', v);
    RAISE NOTICE 'T2 PASSED: rows=%', v;
END $$;

-- T3: Partitions created
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.show_chunks('ct_test'); ASSERT v >= 3, format('T3 FAILED: %s', v);
    RAISE NOTICE 'T3 PASSED: chunks=%', v;
END $$;

-- T4: Table is partitioned (relkind='p')
DO $$ DECLARE v CHAR; BEGIN
    SELECT relkind INTO v FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='public' AND c.relname='ct_test';
    ASSERT v = 'p', format('T4 FAILED: %s', v); RAISE NOTICE 'T4 PASSED: relkind=p';
END $$;

-- T5: drop_chunks
DO $$ DECLARE d INT; b BIGINT; a BIGINT; BEGIN
    SELECT count(*) INTO b FROM lakets.show_chunks('ct_test');
    SELECT lakets.drop_chunks('ct_test', '1 day') INTO d;
    SELECT count(*) INTO a FROM lakets.show_chunks('ct_test');
    ASSERT d > 0 AND a < b, 'T5 FAILED'; RAISE NOTICE 'T5 PASSED: dropped=% before=% after=%', d, b, a;
END $$;

-- T6: set_chunk_interval
DO $$ DECLARE v INTERVAL; BEGIN
    PERFORM lakets.set_chunk_interval('ct_test', '6 hours');
    SELECT chunk_interval INTO v FROM lakets._chronotable_registry WHERE table_name='ct_test';
    ASSERT v = '6 hours'::interval, 'T6 FAILED'; RAISE NOTICE 'T6 PASSED: interval=%', v;
END $$;

-- T7: if_not_exists (backward compat via create_hypertable)
DO $$ DECLARE v1 INT; v2 INT; BEGIN
    SELECT id INTO v1 FROM lakets._chronotable_registry WHERE table_name='ct_test';
    SELECT lakets.create_hypertable('ct_test', 'time', '1 day', 'public', TRUE) INTO v2;
    ASSERT v1 = v2, 'T7 FAILED'; RAISE NOTICE 'T7 PASSED: backward compat if_not_exists';
END $$;

-- T8: _chronotable_registry view works
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets._chronotable_registry WHERE table_name='ct_test';
    ASSERT v = 1, 'T8 FAILED'; RAISE NOTICE 'T8 PASSED: _chronotable_registry view ok';
END $$;

-- Cleanup
DROP TABLE IF EXISTS public.ct_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ct_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ct_test';
SELECT 'ALL CHRONOTABLE TESTS PASSED' as result;
