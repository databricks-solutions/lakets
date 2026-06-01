-- LakeTS Tiering tests. Run: psql "$LAKETS_URL" -v ON_ERROR_STOP=1 -f tests/test_tiering.sql
\set ON_ERROR_STOP on

-- TEST 1: _cdf_committed_lsn fails closed for a shadow that does not exist.
DO $$
BEGIN
    ASSERT lakets._cdf_committed_lsn('_shadow_does_not_exist') IS NULL,
        'TEST 1 FAILED: expected NULL for a nonexistent shadow';
    RAISE NOTICE 'TEST 1 PASSED: _cdf_committed_lsn fails closed for missing shadow';
END $$;

-- TEST 2: add_tiering_policy registers a 'tiering' policy and sets tiering_enabled.
DO $$
DECLARE
    v_policy_id INT;
    v_enabled BOOLEAN;
    v_ptype TEXT;
BEGIN
    DROP TABLE IF EXISTS public.tier_test CASCADE;
    CREATE TABLE public.tier_test (time TIMESTAMPTZ NOT NULL, v DOUBLE PRECISION);
    PERFORM lakets.create_chronotable('tier_test', 'time', '1 day');

    v_policy_id := lakets.add_tiering_policy('tier_test', '7 days');
    ASSERT v_policy_id IS NOT NULL, 'TEST 2 FAILED: no policy id returned';

    SELECT tiering_enabled INTO v_enabled
    FROM lakets._chronotable_registry WHERE table_name = 'tier_test';
    ASSERT v_enabled, 'TEST 2 FAILED: tiering_enabled not set';

    SELECT policy_type INTO v_ptype
    FROM lakets._policy_registry pr
    JOIN lakets._chronotable_registry hr ON hr.id = pr.chronotable_id
    WHERE hr.table_name = 'tier_test';
    ASSERT v_ptype = 'tiering', 'TEST 2 FAILED: policy_type is not tiering';

    RAISE NOTICE 'TEST 2 PASSED: add_tiering_policy works';
END $$;

-- TEST 3: show_tiering_policy returns the policy; remove_tiering_policy clears it.
DO $$
DECLARE v_cnt INT;
BEGIN
    PERFORM 1 FROM lakets.show_tiering_policy('tier_test');
    PERFORM lakets.remove_tiering_policy('tier_test');
    SELECT count(*) INTO v_cnt FROM lakets.show_tiering_policy('tier_test');
    ASSERT v_cnt = 0, 'TEST 3 FAILED: policy not removed';
    RAISE NOTICE 'TEST 3 PASSED: show/remove tiering policy works';
END $$;

-- TEST 4: _get_chunks_to_tier returns nothing for a non-streaming table
-- (no STREAMING shadow => fail closed).
DO $$
DECLARE v_cnt INT;
BEGIN
    -- recreate policy from TEST 2 teardown
    PERFORM lakets.add_tiering_policy('tier_test', '0 seconds');  -- everything eligible by age
    INSERT INTO lakets._chunk_metadata (chronotable_id, chunk_name, range_start, range_end, status)
    SELECT id, 'tier_test_oldchunk', now() - interval '10 days', now() - interval '9 days', 'active'
    FROM lakets._chronotable_registry WHERE table_name = 'tier_test';

    SELECT count(*) INTO v_cnt FROM lakets._get_chunks_to_tier('tier_test');
    ASSERT v_cnt = 0,
        'TEST 4 FAILED: expected 0 eligible chunks when shadow is not STREAMING';
    RAISE NOTICE 'TEST 4 PASSED: _get_chunks_to_tier fails closed without STREAMING CDF';
END $$;

-- TEST 5: tier_chunk refuses to drop (returns FALSE, partition row intact)
-- when the CDF gate is not satisfiable.
DO $$
DECLARE v_ok BOOLEAN; v_status TEXT;
BEGIN
    v_ok := lakets.tier_chunk('tier_test_oldchunk');
    ASSERT v_ok = FALSE, 'TEST 5 FAILED: tier_chunk should refuse without STREAMING CDF';
    SELECT status INTO v_status FROM lakets._chunk_metadata WHERE chunk_name = 'tier_test_oldchunk';
    ASSERT v_status = 'active', 'TEST 5 FAILED: chunk should remain active (not tiered)';
    RAISE NOTICE 'TEST 5 PASSED: tier_chunk fails closed';
END $$;

-- TEST 6: untier_chunk restores tiered -> active.
DO $$
DECLARE v_status TEXT;
BEGIN
    UPDATE lakets._chunk_metadata SET status = 'tiered', tiered_at = now()
    WHERE chunk_name = 'tier_test_oldchunk';
    PERFORM lakets.untier_chunk('tier_test_oldchunk');
    SELECT status INTO v_status FROM lakets._chunk_metadata WHERE chunk_name = 'tier_test_oldchunk';
    ASSERT v_status = 'active', 'TEST 6 FAILED: untier_chunk did not restore active';
    RAISE NOTICE 'TEST 6 PASSED: untier_chunk restores active';
END $$;

-- TEST 7: show_tiering_status reports counts and classifies cdf_status='NONE'
-- when the table is not in wal2delta.tables.
DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM lakets.show_tiering_status('tier_test');
    ASSERT r.table_name = 'tier_test', 'TEST 7 FAILED: wrong/no row';
    ASSERT r.pending_chunks >= 1, 'TEST 7 FAILED: expected >=1 pending chunk';
    ASSERT r.cdf_status = 'NONE', 'TEST 7 FAILED: expected cdf_status NONE without CDF';
    ASSERT r.caught_up = FALSE, 'TEST 7 FAILED: caught_up should be false without CDF';
    RAISE NOTICE 'TEST 7 PASSED: show_tiering_status reports gate state';
END $$;

-- TEST 8: the write-tracking trigger stamps last_write_lsn on the chunk that
-- received rows and leaves other chunks untouched (no CDF needed).
DO $$
DECLARE
    v_id INT;
    v_lsn_hot PG_LSN;
    v_lsn_seeded PG_LSN;
BEGIN
    SELECT id INTO v_id FROM lakets._chronotable_registry WHERE table_name = 'tier_test';

    -- Ensure a partition exists for "now" so the insert has somewhere to route.
    PERFORM lakets._ensure_partitions(v_id, p_range_start := now(), p_range_end := now());

    -- Pin the seeded old chunk's watermark to a known value; it must NOT move.
    UPDATE lakets._chunk_metadata SET last_write_lsn = '0/1'::pg_lsn
    WHERE chunk_name = 'tier_test_oldchunk';

    INSERT INTO public.tier_test (time, v) VALUES (now(), 1.0);

    -- The hot chunk that received the row is stamped with a real WAL position.
    SELECT max(last_write_lsn) INTO v_lsn_hot
    FROM lakets._chunk_metadata
    WHERE chronotable_id = v_id AND chunk_name <> 'tier_test_oldchunk';
    ASSERT v_lsn_hot IS NOT NULL AND v_lsn_hot <> '0/1'::pg_lsn,
        'TEST 8 FAILED: hot chunk was not stamped by the write-tracking trigger';

    -- The unrelated old chunk is untouched.
    SELECT last_write_lsn INTO v_lsn_seeded
    FROM lakets._chunk_metadata WHERE chunk_name = 'tier_test_oldchunk';
    ASSERT v_lsn_seeded = '0/1'::pg_lsn,
        'TEST 8 FAILED: a hot-chunk write bumped an unrelated cold chunk watermark';

    RAISE NOTICE 'TEST 8 PASSED: write-tracking stamps only the written chunk';
END $$;

SELECT 'ALL TIERING TESTS PASSED' AS result;
