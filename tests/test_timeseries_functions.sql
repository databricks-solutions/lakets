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

-- T12: time_bucket with year boundaries (Dec → Jan)
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('1 month'::interval, '2026-01-15 10:00:00+00'::timestamptz) INTO v;
    ASSERT v = '2026-01-01 00:00:00+00'::timestamptz;
    RAISE NOTICE 'T12 PASSED: year boundary bucket=%', v;
END $$;

-- T13: time_bucket with custom origin
DO $$ DECLARE v TIMESTAMPTZ; BEGIN
    SELECT lakets.time_bucket('15 minutes'::interval, '2026-03-25 14:37:22+00'::timestamptz, '2026-03-25 00:05:00+00'::timestamptz) INTO v;
    ASSERT v = '2026-03-25 14:35:00+00'::timestamptz;
    RAISE NOTICE 'T13 PASSED: custom origin bucket=%', v;
END $$;

-- T14: interpolate returns NULL when prev_value is NULL
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.interpolate(NULL, NULL, 30.0,
        '2026-01-01 10:00+00'::timestamptz, '2026-01-01 11:00+00'::timestamptz, '2026-01-01 12:00+00'::timestamptz) INTO v;
    ASSERT v IS NULL, format('expected NULL, got %s', v);
    RAISE NOTICE 'T14 PASSED: interpolate returns NULL for missing bound';
END $$;

-- T15: interpolate returns prev_value when timestamps equal
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.interpolate(NULL, 10.0, 30.0,
        '2026-01-01 10:00+00'::timestamptz, '2026-01-01 10:30+00'::timestamptz, '2026-01-01 10:00+00'::timestamptz) INTO v;
    ASSERT v = 10.0, format('expected 10.0, got %s', v);
    RAISE NOTICE 'T15 PASSED: interpolate same timestamps returns prev_value=%', v;
END $$;

-- T16: rate returns NULL when timestamps equal
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.rate(200.0, 100.0, '2026-01-01 01:00+00'::timestamptz, '2026-01-01 01:00+00'::timestamptz) INTO v;
    ASSERT v IS NULL, format('expected NULL, got %s', v);
    RAISE NOTICE 'T16 PASSED: rate returns NULL for equal timestamps';
END $$;

-- T17: rate returns NULL when prev values are NULL
DO $$ DECLARE v DOUBLE PRECISION; BEGIN
    SELECT lakets.rate(200.0, NULL, '2026-01-01 01:00+00'::timestamptz, '2026-01-01 00:00+00'::timestamptz) INTO v;
    ASSERT v IS NULL, format('expected NULL, got %s', v);
    RAISE NOTICE 'T17 PASSED: rate returns NULL for NULL prev';
END $$;

-- T18: histogram boundary conditions
DO $$ BEGIN
    ASSERT lakets.histogram(0.0, 0.0, 100.0, 10) = 0, 'value=min should be bucket 0';
    ASSERT lakets.histogram(100.0, 0.0, 100.0, 10) = 9, 'value=max should be last bucket';
    ASSERT lakets.histogram(-5.0, 0.0, 100.0, 10) = 0, 'value<min should be bucket 0';
    RAISE NOTICE 'T18 PASSED: histogram boundary conditions';
END $$;

-- T19: first/last with single row
DO $$ DECLARE vf DOUBLE PRECISION; vl DOUBLE PRECISION; BEGIN
    CREATE TEMPORARY TABLE IF NOT EXISTS _t19 (time TIMESTAMPTZ, v DOUBLE PRECISION);
    TRUNCATE _t19;
    INSERT INTO _t19 VALUES ('2026-01-01 10:00+00', 42.0);
    SELECT lakets.first(v, time), lakets.last(v, time) INTO vf, vl FROM _t19;
    ASSERT vf = 42.0 AND vl = 42.0, format('expected 42.0, got first=%s last=%s', vf, vl);
    RAISE NOTICE 'T19 PASSED: single-row first=%, last=%', vf, vl;
    DROP TABLE _t19;
END $$;

-- T20: time_bucket_gapfill with 1-bucket range
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.time_bucket_gapfill(
        '1 hour'::interval, '2026-03-25 10:00+00'::timestamptz, '2026-03-25 10:00+00'::timestamptz);
    ASSERT v = 1, format('expected 1 bucket, got %s', v);
    RAISE NOTICE 'T20 PASSED: gapfill single bucket, count=%', v;
END $$;

SELECT 'ALL TIMESERIES FUNCTION TESTS PASSED' as result;
