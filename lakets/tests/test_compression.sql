-- =============================================================================
-- LakeTS Compression & Tiering Tests
-- =============================================================================
DROP TABLE IF EXISTS public.comp_test CASCADE;
DELETE FROM lakets._policy_registry WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='comp_test');
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='comp_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='comp_test';

CREATE TABLE public.comp_test (time TIMESTAMPTZ NOT NULL, val DOUBLE PRECISION);
INSERT INTO comp_test SELECT now()-(i||' hours')::interval, random()*100 FROM generate_series(1,240) s(i);
SELECT lakets.create_chronotable('comp_test','time','1 day');

-- T1: Add compression policy
DO $$ DECLARE v INT; BEGIN
    SELECT lakets.add_compression_policy('comp_test', '3 days', 'val') INTO v;
    ASSERT v IS NOT NULL; RAISE NOTICE 'T1 PASSED: policy id=%', v;
END $$;

-- T2: Show compression policy
DO $$ DECLARE v TEXT; BEGIN
    SELECT compress_after INTO v FROM lakets.show_compression_policy('comp_test');
    ASSERT v = '3 days'; RAISE NOTICE 'T2 PASSED: compress_after=%', v;
END $$;

-- T3: Get chunks to compress
DO $$ DECLARE v BIGINT; BEGIN
    SELECT count(*) INTO v FROM lakets._get_chunks_to_compress('comp_test');
    ASSERT v > 0; RAISE NOTICE 'T3 PASSED: % eligible chunks', v;
END $$;

-- T4: Compress a chunk
DO $$ DECLARE v_name TEXT; v_status TEXT; BEGIN
    SELECT chunk_name INTO v_name FROM lakets._get_chunks_to_compress('comp_test') LIMIT 1;
    PERFORM lakets.compress_chunk(v_name);
    SELECT status INTO v_status FROM lakets._chunk_metadata WHERE chunk_name=v_name;
    ASSERT v_status = 'compressed'; RAISE NOTICE 'T4 PASSED: status=%', v_status;
END $$;

-- T5: Decompress chunk
DO $$ DECLARE v_name TEXT; v_status TEXT; BEGIN
    SELECT chunk_name INTO v_name FROM lakets._chunk_metadata WHERE status='compressed' AND chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='comp_test') LIMIT 1;
    PERFORM lakets.decompress_chunk(v_name);
    SELECT status INTO v_status FROM lakets._chunk_metadata WHERE chunk_name=v_name;
    ASSERT v_status = 'active'; RAISE NOTICE 'T5 PASSED: decompressed back to active';
END $$;

-- T6: Remove compression policy
DO $$ DECLARE v BOOLEAN; BEGIN
    PERFORM lakets.remove_compression_policy('comp_test');
    SELECT compression_enabled INTO v FROM lakets._chronotable_registry WHERE table_name='comp_test';
    ASSERT v = FALSE; RAISE NOTICE 'T6 PASSED: policy removed';
END $$;

DROP TABLE IF EXISTS public.comp_test CASCADE;
DELETE FROM lakets._policy_registry WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='comp_test');
DELETE FROM lakets._chunk_metadata WHERE chronotable_id IN (SELECT id FROM lakets._chronotable_registry WHERE table_name='comp_test');
DELETE FROM lakets._chronotable_registry WHERE table_name='comp_test';
SELECT 'ALL COMPRESSION TESTS PASSED' as result;
