-- =============================================================================
-- LakeTS Monitoring Tests
-- =============================================================================

-- T1: lakets_metrics returns rows
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.lakets_metrics();
    ASSERT v > 0; RAISE NOTICE 'T1 PASSED: metrics rows=%', v;
END $$;

-- T2: database_size_bytes metric exists
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT metric_value INTO v FROM lakets.lakets_metrics() WHERE metric_name='lakets_database_size_bytes';
    ASSERT v > 0; RAISE NOTICE 'T2 PASSED: db_size=% bytes', v;
END $$;

-- T3: query_stats doesn't error (may return 0 rows if pg_stat_statements unavailable)
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.query_stats(5);
    RAISE NOTICE 'T3 PASSED: query_stats returned % rows', v;
END $$;

-- T4: chunk_health returns rows for existing ChronoTables
DO $$
DECLARE
    v_count BIGINT;
    v_total_chunks BIGINT;
    v_active_chunks BIGINT;
BEGIN
    -- Create a test ChronoTable to ensure chunk_health has data
    DROP TABLE IF EXISTS public.mon_test CASCADE;
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_test';

    CREATE TABLE public.mon_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
    INSERT INTO mon_test SELECT now() - (i || ' hours')::interval, random() * 100
    FROM generate_series(1, 72) s(i);
    PERFORM lakets.create_chronotable('mon_test', 'time', '1 day');

    SELECT count(*) INTO v_count FROM lakets.chunk_health();
    ASSERT v_count > 0, format('chunk_health returned 0 rows, expected > 0');

    -- Verify column values for our test table
    SELECT total_chunks, active_chunks INTO v_total_chunks, v_active_chunks
    FROM lakets.chunk_health()
    WHERE hypertable = 'public.mon_test';

    ASSERT v_total_chunks > 0, format('expected total_chunks > 0, got %s', v_total_chunks);
    ASSERT v_active_chunks > 0, format('expected active_chunks > 0, got %s', v_active_chunks);
    ASSERT v_active_chunks <= v_total_chunks, 'active_chunks > total_chunks';

    RAISE NOTICE 'T4 PASSED: chunk_health returned % rows, mon_test has %/% active/total chunks',
        v_count, v_active_chunks, v_total_chunks;

    -- Cleanup
    DROP TABLE IF EXISTS public.mon_test CASCADE;
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_test';
END $$;

-- T5: chunk_health reports compressed chunks correctly
DO $$
DECLARE
    v_compressed BIGINT;
    v_chunk_name TEXT;
BEGIN
    -- Create ChronoTable with enough data to compress
    DROP TABLE IF EXISTS public.mon_comp_test CASCADE;
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test'
    );
    DELETE FROM lakets._policy_registry WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test';

    CREATE TABLE public.mon_comp_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
    INSERT INTO mon_comp_test SELECT now() - (i || ' hours')::interval, random() * 100
    FROM generate_series(1, 240) s(i);
    PERFORM lakets.create_chronotable('mon_comp_test', 'time', '1 day');
    PERFORM lakets.add_compression_policy('mon_comp_test', '3 days', 'val');

    -- Compress one chunk
    SELECT chunk_name INTO v_chunk_name FROM lakets._get_chunks_to_compress('mon_comp_test') LIMIT 1;
    IF v_chunk_name IS NOT NULL THEN
        PERFORM lakets.compress_chunk(v_chunk_name);

        SELECT compressed_chunks INTO v_compressed
        FROM lakets.chunk_health()
        WHERE hypertable = 'public.mon_comp_test';

        ASSERT v_compressed >= 1, format('expected >= 1 compressed chunk, got %s', v_compressed);
        RAISE NOTICE 'T5 PASSED: chunk_health reports % compressed chunks', v_compressed;
    ELSE
        RAISE NOTICE 'T5 SKIPPED: no eligible chunks to compress';
    END IF;

    -- Cleanup
    DROP TABLE IF EXISTS public.mon_comp_test CASCADE;
    DELETE FROM lakets._policy_registry WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test'
    );
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_comp_test';
END $$;

-- T6: lakets_metrics includes all expected metric names
DO $$
DECLARE
    v_names TEXT[];
BEGIN
    SELECT array_agg(DISTINCT metric_name ORDER BY metric_name) INTO v_names
    FROM lakets.lakets_metrics();

    ASSERT 'lakets_database_size_bytes' = ANY(v_names), 'missing lakets_database_size_bytes';
    ASSERT 'lakets_hypertables_total' = ANY(v_names), 'missing lakets_hypertables_total';
    RAISE NOTICE 'T6 PASSED: metrics include expected names: %', v_names;
END $$;

-- T7: chunk_health oldest/newest timestamps are valid
DO $$
DECLARE
    v_oldest TIMESTAMPTZ;
    v_newest TIMESTAMPTZ;
BEGIN
    DROP TABLE IF EXISTS public.mon_ts_test CASCADE;
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_ts_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_ts_test';

    CREATE TABLE public.mon_ts_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
    INSERT INTO mon_ts_test SELECT now() - (i || ' hours')::interval, random() * 100
    FROM generate_series(1, 72) s(i);
    PERFORM lakets.create_chronotable('mon_ts_test', 'time', '1 day');

    SELECT oldest_active, newest_active INTO v_oldest, v_newest
    FROM lakets.chunk_health()
    WHERE hypertable = 'public.mon_ts_test';

    ASSERT v_oldest IS NOT NULL, 'oldest_active is NULL';
    ASSERT v_newest IS NOT NULL, 'newest_active is NULL';
    ASSERT v_oldest <= v_newest, format('oldest (%s) > newest (%s)', v_oldest, v_newest);
    RAISE NOTICE 'T7 PASSED: oldest_active=%, newest_active=%', v_oldest, v_newest;

    -- Cleanup
    DROP TABLE IF EXISTS public.mon_ts_test CASCADE;
    DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
        SELECT id FROM lakets._chronotable_registry WHERE table_name = 'mon_ts_test'
    );
    DELETE FROM lakets._chronotable_registry WHERE table_name = 'mon_ts_test';
END $$;

SELECT 'ALL MONITORING TESTS PASSED' as result;
