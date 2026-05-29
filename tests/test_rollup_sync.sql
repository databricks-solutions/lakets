-- =============================================================================
-- LakeTS RollUp CDF Sync Tests
-- =============================================================================

-- Test 1: lakets_cdf schema exists
DO $$
DECLARE v_exists BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'lakets_cdf')
    INTO v_exists;
    ASSERT v_exists, 'TEST 1 FAILED: lakets_cdf schema not created';
    RAISE NOTICE 'TEST 1 PASSED: lakets_cdf schema exists';
END $$;

-- Test 2: _rollup_registry has sync columns
DO $$
DECLARE v_sync INT; v_shadow INT;
BEGIN
    SELECT count(*) INTO v_sync FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='sync_enabled';
    SELECT count(*) INTO v_shadow FROM information_schema.columns
      WHERE table_schema='lakets' AND table_name='_rollup_registry' AND column_name='shadow_table_name';
    ASSERT v_sync = 1, 'TEST 2 FAILED: sync_enabled column missing';
    ASSERT v_shadow = 1, 'TEST 2 FAILED: shadow_table_name column missing';
    RAISE NOTICE 'TEST 2 PASSED: registry sync columns present';
END $$;

SELECT 'TASK 1 TESTS PASSED' as result;
