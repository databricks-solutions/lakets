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

SELECT 'ALL MONITORING TESTS PASSED' as result;
