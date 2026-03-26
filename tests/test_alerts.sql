-- =============================================================================
-- LakeTS Alert Tests
-- Note: alert_check/deadman use string queries, so we use single-quote
-- escaping instead of $$ to avoid nesting issues.
-- =============================================================================
DROP TABLE IF EXISTS public.alert_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name = 'alert_test');
DELETE FROM lakets._chronotable_registry WHERE table_name = 'alert_test';

CREATE TABLE public.alert_test (time TIMESTAMPTZ NOT NULL, host TEXT NOT NULL, cpu DOUBLE PRECISION);
INSERT INTO alert_test SELECT now() - (i || ' min')::interval, 'h-' || (i % 3), 50 + random() * 50 FROM generate_series(1, 100) AS s(i);
INSERT INTO alert_test VALUES (now() - '10 minutes'::interval, 'stale-host', 50.0);
SELECT lakets.create_chronotable('alert_test', 'time', '1 day');

-- T1: alert_check fires for high CPU
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.alert_check(
        'high_cpu',
        'SELECT host, max(cpu) as peak FROM alert_test GROUP BY host HAVING max(cpu) > 80',
        'critical'
    );
    ASSERT v > 0;
    RAISE NOTICE 'T1 PASSED: % alerts fired', v;
END $$;

-- T2: alert_check returns JSONB data
DO $$ DECLARE v JSONB; BEGIN
    SELECT alert_data INTO v FROM lakets.alert_check(
        'high_cpu',
        'SELECT host, max(cpu) as peak FROM alert_test GROUP BY host HAVING max(cpu) > 80'
    ) LIMIT 1;
    ASSERT v ? 'host';
    RAISE NOTICE 'T2 PASSED: alert_data has host key';
END $$;

-- T3: alert_check returns 0 for impossible threshold
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.alert_check(
        'low_cpu',
        'SELECT host FROM alert_test GROUP BY host HAVING max(cpu) > 999'
    );
    ASSERT v = 0;
    RAISE NOTICE 'T3 PASSED: 0 alerts for impossible threshold';
END $$;

-- T4: alert_deadman detects stale host
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.alert_deadman('stale', 'alert_test', 'host', '5 minutes');
    ASSERT v >= 1;
    RAISE NOTICE 'T4 PASSED: % stale hosts detected', v;
END $$;

-- Cleanup
DROP TABLE IF EXISTS public.alert_test CASCADE;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name = 'alert_test');
DELETE FROM lakets._chronotable_registry WHERE table_name = 'alert_test';
SELECT 'ALL ALERT TESTS PASSED' as result;
