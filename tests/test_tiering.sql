-- LakeTS Tiering tests. Run: psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_tiering.sql
\set ON_ERROR_STOP on

-- TEST 1: _cdf_committed_lsn fails closed for a shadow that does not exist.
DO $$
BEGIN
    ASSERT lakets._cdf_committed_lsn('_shadow_does_not_exist') IS NULL,
        'TEST 1 FAILED: expected NULL for a nonexistent shadow';
    RAISE NOTICE 'TEST 1 PASSED: _cdf_committed_lsn fails closed for missing shadow';
END $$;

SELECT 'ALL TIERING TESTS PASSED' AS result;
