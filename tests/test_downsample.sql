-- =============================================================================
-- LakeTS Downsampling Pipeline Tests
-- =============================================================================
DELETE FROM lakets._downsample_registry WHERE name='test_ds';

-- T1: Create pipeline
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.create_downsample_pipeline('test_ds', 'metrics', ARRAY['1 minute','1 hour','1 day']::INTERVAL[], ARRAY['30 days','1 year','100 years']::INTERVAL[], ARRAY['avg(cpu)','max(mem)'], ARRAY['host']) INTO v;
    ASSERT v IS NOT NULL; RAISE NOTICE 'T1 PASSED: pipeline id=%', v;
END $$;

-- T2: Show pipelines
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.show_downsample_pipelines() WHERE name='test_ds';
    ASSERT v = 1; RAISE NOTICE 'T2 PASSED: show found 1 pipeline';
END $$;

-- T3: Auto-resolution returns options
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets.query_auto_resolution('test_ds', now() - '30 days'::interval);
    ASSERT v >= 3; RAISE NOTICE 'T3 PASSED: auto_resolution returned % options', v;
END $$;

-- T4: Auto-resolution includes raw source
DO $$ DECLARE v TEXT; BEGIN
    SELECT delta_table INTO v FROM lakets.query_auto_resolution('test_ds', now() - '1 hour'::interval) WHERE resolution = '0 seconds'::interval;
    ASSERT v LIKE '%Lakebase hot%'; RAISE NOTICE 'T4 PASSED: raw source included';
END $$;

-- T5: Drop pipeline
DO $$ DECLARE v BIGINT; BEGIN
    PERFORM lakets.drop_downsample_pipeline('test_ds');
    SELECT count(*) INTO v FROM lakets._downsample_registry WHERE name='test_ds';
    ASSERT v = 0; RAISE NOTICE 'T5 PASSED: pipeline dropped';
END $$;

-- T6: Duplicate rejection
DO $$ BEGIN
    PERFORM lakets.create_downsample_pipeline('test_dup', 'x', ARRAY['1 hour']::INTERVAL[], ARRAY['30 days']::INTERVAL[], ARRAY['avg(v)']);
    BEGIN
        PERFORM lakets.create_downsample_pipeline('test_dup', 'x', ARRAY['1 hour']::INTERVAL[], ARRAY['30 days']::INTERVAL[], ARRAY['avg(v)']);
        RAISE NOTICE 'T6 FAILED: should reject duplicate';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'T6 PASSED: duplicate rejected';
    END;
    DELETE FROM lakets._downsample_registry WHERE name='test_dup';
END $$;

SELECT 'ALL DOWNSAMPLE TESTS PASSED' as result;
