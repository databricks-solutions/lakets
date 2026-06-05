-- =============================================================================
-- LakeTS Shadow Sync Tests
-- =============================================================================

-- Setup: create ChronoTable
DROP TABLE IF EXISTS public.sync_test CASCADE;
DROP TABLE IF EXISTS lakets_cdf._shadow_sync_test;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'sync_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'sync_test';

CREATE TABLE public.sync_test (
    time TIMESTAMPTZ NOT NULL,
    sensor TEXT NOT NULL,
    reading DOUBLE PRECISION
);
INSERT INTO public.sync_test VALUES (now(), 'setup', 0.0);
SELECT lakets.create_chronotable('sync_test', 'time', '1 day');

-- Test 1: enable_sync creates shadow table
DO $$
DECLARE v_exists BOOLEAN;
BEGIN
    PERFORM lakets.enable_sync('sync_test');
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'lakets_cdf' AND table_name = '_shadow_sync_test'
    ) INTO v_exists;
    ASSERT v_exists, 'TEST 1 FAILED: shadow table not created';
    RAISE NOTICE 'TEST 1 PASSED: shadow table created';
END $$;

-- Test 2: shadow table has REPLICA IDENTITY FULL
DO $$
DECLARE v_ri CHAR;
BEGIN
    SELECT relreplident INTO v_ri
    FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'lakets_cdf' AND c.relname = '_shadow_sync_test';
    ASSERT v_ri = 'f', format('TEST 2 FAILED: replica identity=%s', v_ri);
    RAISE NOTICE 'TEST 2 PASSED: REPLICA IDENTITY FULL';
END $$;

-- Test 3: INSERTs forwarded to shadow
DO $$
DECLARE v_count BIGINT;
BEGIN
    INSERT INTO sync_test VALUES (now(), 'test_3a', 42.0), (now(), 'test_3b', 84.0);
    SELECT count(*) INTO v_count FROM lakets_cdf._shadow_sync_test;
    ASSERT v_count >= 2, format('TEST 3 FAILED: shadow has %s rows', v_count);
    RAISE NOTICE 'TEST 3 PASSED: % rows forwarded to shadow', v_count;
END $$;

-- Test 3b: source DELETE removes the matching row from the shadow (true mirror)
DO $$
DECLARE v_n BIGINT;
BEGIN
    DELETE FROM sync_test WHERE sensor = 'test_3a';
    SELECT count(*) INTO v_n FROM lakets_cdf._shadow_sync_test WHERE sensor = 'test_3a';
    ASSERT v_n = 0, format('TEST 3b FAILED: delete not mirrored (%s)', v_n);
    RAISE NOTICE 'TEST 3b PASSED: delete mirrored to shadow';
END $$;

-- Test 4: registry updated
DO $$
DECLARE v_sync BOOLEAN; v_shadow TEXT;
BEGIN
    SELECT sync_enabled, shadow_table_name INTO v_sync, v_shadow
    FROM lakets._chronotable_registry WHERE table_name = 'sync_test';
    ASSERT v_sync = TRUE, 'TEST 4 FAILED: sync_enabled not true';
    ASSERT v_shadow = '_shadow_sync_test',
        format('TEST 4 FAILED: shadow=%s', v_shadow);
    RAISE NOTICE 'TEST 4 PASSED: registry updated correctly';
END $$;

-- Test 5: disable_sync cleans up
DO $$
DECLARE v_sync BOOLEAN; v_shadow TEXT; v_trig_count BIGINT;
BEGIN
    PERFORM lakets.disable_sync('sync_test');
    SELECT sync_enabled, shadow_table_name INTO v_sync, v_shadow
    FROM lakets._chronotable_registry WHERE table_name = 'sync_test';
    ASSERT v_sync = FALSE, 'TEST 5a FAILED: sync still enabled';
    ASSERT v_shadow IS NULL, 'TEST 5b FAILED: shadow not cleared';

    -- Scope to sync_test's own parent + partitions; trg_lakets_sync may also
    -- exist on other synced tables in the same database (test isolation).
    SELECT count(*) INTO v_trig_count
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE t.tgname = 'trg_lakets_sync'
      AND (c.relname = 'sync_test' OR c.relname LIKE 'sync\_test\_%');
    ASSERT v_trig_count = 0, format('TEST 5c FAILED: %s triggers remain on sync_test', v_trig_count);
    RAISE NOTICE 'TEST 5 PASSED: disable_sync cleaned up';
END $$;

-- Cleanup
DROP TABLE IF EXISTS public.sync_test CASCADE;
DROP TABLE IF EXISTS lakets_cdf._shadow_sync_test;
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (
    SELECT id FROM lakets._chronotable_registry WHERE table_name = 'sync_test'
);
DELETE FROM lakets._chronotable_registry WHERE table_name = 'sync_test';

SELECT 'ALL SHADOW SYNC TESTS PASSED' as result;
