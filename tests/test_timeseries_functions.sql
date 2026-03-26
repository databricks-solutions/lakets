-- =============================================================================
-- LakeTS Time Series Function Tests
-- =============================================================================

-- T1-T4: time_bucket
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('15 minutes'::interval, '2026-03-25 14:37:22+00'::timestamptz) INTO v;
    ASSERT v = '2026-03-25 14:30:00+00'::timestamptz; RAISE NOTICE 'T1 PASSED: 15min bucket';
END $$;
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('1 hour'::interval, '2026-03-25 14:37:22+00'::timestamptz) INTO v;
    ASSERT v = '2026-03-25 14:00:00+00'::timestamptz; RAISE NOTICE 'T2 PASSED: 1hr bucket';
END $$;
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('1 month'::interval, '2026-03-25 14:37:22+00'::timestamptz) INTO v;
    ASSERT v = '2026-03-01 00:00:00+00'::timestamptz; RAISE NOTICE 'T3 PASSED: monthly bucket';
END $$;
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('3 months'::interval, '2026-08-15 10:00:00+00'::timestamptz) INTO v;
    ASSERT v = '2026-07-01 00:00:00+00'::timestamptz; RAISE NOTICE 'T4 PASSED: quarterly bucket';
END $$;

-- T5: first/last
DO $$ DECLARE vf DOUBLE PRECISION; vl DOUBLE PRECISION; BEGIN
    CREATE TEMPORARY TABLE IF NOT EXISTS _t (time TIMESTAMPTZ, v DOUBLE PRECISION);
    TRUNCATE _t; INSERT INTO _t VALUES ('2026-01-01 10:00+00',10),('2026-01-01 11:00+00',20),('2026-01-01 12:00+00',30);
    SELECT lakets.first(v, time), lakets.last(v, time) INTO vf, vl FROM _t;
    ASSERT vf = 10 AND vl = 30; RAISE NOTICE 'T5 PASSED: first=%, last=%', vf, vl;
    DROP TABLE _t;
END $$;

-- T6: time_bucket_gapfill
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.time_bucket_gapfill('1 hour'::interval, '2026-03-25 10:00+00'::timestamptz, '2026-03-25 15:00+00'::timestamptz);
    ASSERT v = 6; RAISE NOTICE 'T6 PASSED: gapfill 6 buckets';
END $$;

-- T7: locf
DO $$ BEGIN
    ASSERT lakets.locf(NULL, 10.0) = 10.0; ASSERT lakets.locf(20.0, 10.0) = 20.0; ASSERT lakets.locf(NULL, NULL) IS NULL;
    RAISE NOTICE 'T7 PASSED: locf';
END $$;

-- T8: interpolate
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.interpolate(NULL, 10.0, 30.0, '2026-01-01 10:00+00'::timestamptz, '2026-01-01 11:00+00'::timestamptz, '2026-01-01 12:00+00'::timestamptz) INTO v;
    ASSERT abs(v - 20.0) < 0.001; RAISE NOTICE 'T8 PASSED: interpolate midpoint=%', v;
END $$;

-- T9: delta
DO $$ BEGIN
    ASSERT lakets.delta(100.0, 80.0) = 20.0;
    ASSERT lakets.delta(50.0, 80.0, TRUE) = 50.0;
    ASSERT lakets.delta(50.0, 80.0, FALSE) = -30.0;
    ASSERT lakets.delta(100.0, NULL) IS NULL;
    RAISE NOTICE 'T9 PASSED: delta';
END $$;

-- T10: rate
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.rate(200.0, 100.0, '2026-01-01 01:00+00'::timestamptz, '2026-01-01 00:00+00'::timestamptz) INTO v;
    ASSERT abs(v - 100.0/3600.0) < 0.0001; RAISE NOTICE 'T10 PASSED: rate=%', round(v::numeric, 6);
END $$;

-- T11: histogram
DO $$ BEGIN
    ASSERT lakets.histogram(15.0, 0.0, 100.0, 10) = 1;
    ASSERT lakets.histogram(95.0, 0.0, 100.0, 10) = 9;
    ASSERT lakets.histogram(50.0, 0.0, 100.0, 10) = 5;
    ASSERT lakets.histogram(NULL, 0.0, 100.0, 10) IS NULL;
    RAISE NOTICE 'T11 PASSED: histogram';
END $$;

SELECT 'ALL TIMESERIES FUNCTION TESTS PASSED' as result;
