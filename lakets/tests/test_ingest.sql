-- =============================================================================
-- LakeTS Ingest Tests
-- =============================================================================
DROP TABLE IF EXISTS public.ing_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ing_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ing_test';

CREATE TABLE public.ing_test (time TIMESTAMPTZ NOT NULL, host TEXT NOT NULL, cpu DOUBLE PRECISION);
INSERT INTO ing_test VALUES (now(), 'setup', 0.0);
SELECT lakets.create_chronotable('ing_test','time','1 day');

-- T1: ingest_batch inserts rows
DO $$ DECLARE v INT; v_before BIGINT; v_after BIGINT; BEGIN
    SELECT count(*) INTO v_before FROM ing_test;
    SELECT lakets.ingest_batch('ing_test', '[
        {"time": "2026-03-25T17:00:00Z", "host": "batch-1", "cpu": 55.5},
        {"time": "2026-03-25T17:00:01Z", "host": "batch-2", "cpu": 66.6},
        {"time": "2026-03-25T17:00:02Z", "host": "batch-3", "cpu": 77.7}
    ]'::JSONB) INTO v;
    SELECT count(*) INTO v_after FROM ing_test;
    ASSERT v = 3 AND v_after = v_before + 3; RAISE NOTICE 'T1 PASSED: inserted %, total % -> %', v, v_before, v_after;
END $$;

-- T2: ingest_batch rejects non-array
DO $$ BEGIN
    BEGIN
        PERFORM lakets.ingest_batch('ing_test', '{"not": "array"}'::JSONB);
        RAISE NOTICE 'T2 FAILED: should reject non-array';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'T2 PASSED: non-array rejected';
    END;
END $$;

-- T3: ingest_prometheus (needs a table with metric_name, labels, value)
DO $$ BEGIN
    CREATE TABLE IF NOT EXISTS public.prom_test (time TIMESTAMPTZ NOT NULL, metric_name TEXT, labels JSONB, value DOUBLE PRECISION);
    PERFORM lakets.ingest_prometheus('prom_test', 'cpu_usage', '{"host":"web-01","env":"prod"}'::JSONB, 72.5, '2026-03-25 17:00:00+00'::timestamptz);
    PERFORM lakets.ingest_prometheus('prom_test', 'mem_usage', '{"host":"web-01"}'::JSONB, 4096.0);
    RAISE NOTICE 'T3 PASSED: prometheus ingest ok';
    DROP TABLE public.prom_test;
END $$;

-- T4: Verify ingested data is queryable
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT cpu INTO v FROM ing_test WHERE host='batch-3';
    ASSERT v = 77.7; RAISE NOTICE 'T4 PASSED: batch data queryable, cpu=%', v;
END $$;

DROP TABLE IF EXISTS public.ing_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='ing_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='ing_test';
SELECT 'ALL INGEST TESTS PASSED' as result;
