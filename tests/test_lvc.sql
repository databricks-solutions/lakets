-- =============================================================================
-- LakeTS Last Value Cache Tests
-- =============================================================================
DROP TABLE IF EXISTS public._lvc_lvc_test; DROP TRIGGER IF EXISTS trg_lakets_lvc ON public.lvc_test;
DELETE FROM lakets._lvc_registry;
DROP TABLE IF EXISTS public.lvc_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='lvc_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='lvc_test';

CREATE TABLE public.lvc_test (time TIMESTAMPTZ NOT NULL, host TEXT NOT NULL, cpu DOUBLE PRECISION, mem DOUBLE PRECISION);
INSERT INTO lvc_test SELECT now()-(i||' min')::interval, 'h-'||(i%3), random()*100, random()*8192 FROM generate_series(1,100) s(i);
SELECT lakets.create_chronotable('lvc_test','time','1 day');

-- T1: Enable LVC
DO $$ DECLARE v BOOLEAN; BEGIN
    PERFORM lakets.enable_lvc('lvc_test', ARRAY['host'], ARRAY['cpu','mem']);
    SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='_lvc_lvc_test') INTO v;
    ASSERT v; RAISE NOTICE 'T1 PASSED: LVC cache table created';
END $$;

-- T2: Insert triggers cache update
DO $$ DECLARE v BIGINT; BEGIN
    INSERT INTO lvc_test VALUES (now(), 'h-0', 95.5, 7000);
    INSERT INTO lvc_test VALUES (now(), 'h-1', 42.0, 3000);
    SELECT count(*) INTO v FROM _lvc_lvc_test;
    ASSERT v >= 2; RAISE NOTICE 'T2 PASSED: cache has % entries', v;
END $$;

-- T3: Upsert updates to latest
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    INSERT INTO lvc_test VALUES (now(), 'h-0', 99.9, 8000);
    SELECT cpu INTO v FROM _lvc_lvc_test WHERE host='h-0';
    ASSERT v = 99.9; RAISE NOTICE 'T3 PASSED: upsert updated cpu to %', v;
END $$;

-- T4: lvc_stats
DO $$ DECLARE v BIGINT; BEGIN
    SELECT cached_series INTO v FROM lakets.lvc_stats() LIMIT 1;
    ASSERT v > 0; RAISE NOTICE 'T4 PASSED: cached_series=%', v;
END $$;

-- T5: Disable LVC
DO $$ DECLARE v BIGINT; BEGIN
    PERFORM lakets.disable_lvc('lvc_test');
    SELECT count(*) INTO v FROM lakets._lvc_registry;
    ASSERT v = 0; RAISE NOTICE 'T5 PASSED: LVC disabled, registry empty';
END $$;

DROP TABLE IF EXISTS public.lvc_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='lvc_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='lvc_test';
SELECT 'ALL LVC TESTS PASSED' as result;
