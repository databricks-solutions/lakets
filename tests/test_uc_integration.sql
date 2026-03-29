-- =============================================================================
-- LakeTS Test Suite: Unity Catalog Integration (Module 14)
-- Tests: register_uc_table, tag_uc_table, get_uc_registrations,
--        unregister_uc_table, and _uc_registry schema constraints.
-- =============================================================================

DO $$
DECLARE
    v_ct_id    INT;
    v_rollup_id INT;
    v_reg_id   INT;
    v_tags     JSONB;
    v_rows     INT;
    v_results  RECORD;
BEGIN
    -- -------------------------------------------------------------------------
    -- Setup: Create a ChronoTable and RollUp with export configured
    -- -------------------------------------------------------------------------
    INSERT INTO lakets._chronotable_registry
        (schema_name, table_name, time_column, chunk_interval)
    VALUES ('public', '_uc_test_metrics', 'time', '1 day')
    ON CONFLICT (schema_name, table_name) DO UPDATE SET time_column = 'time'
    RETURNING id INTO v_ct_id;

    -- Ensure export columns exist (idempotent in case module 13 not applied)
    BEGIN
        ALTER TABLE lakets._rollup_registry
            ADD COLUMN IF NOT EXISTS export_enabled     BOOLEAN DEFAULT FALSE,
            ADD COLUMN IF NOT EXISTS export_delta_table TEXT,
            ADD COLUMN IF NOT EXISTS export_mode        TEXT DEFAULT 'incremental',
            ADD COLUMN IF NOT EXISTS last_exported_at   TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS bucket_column      TEXT DEFAULT 'bucket',
            ADD COLUMN IF NOT EXISTS source_time_column TEXT,
            ADD COLUMN IF NOT EXISTS predicate_injection BOOLEAN DEFAULT TRUE,
            ADD COLUMN IF NOT EXISTS depends_on         INT[] DEFAULT '{}',
            ADD COLUMN IF NOT EXISTS cold_query_text    TEXT,
            ADD COLUMN IF NOT EXISTS last_refreshed_at  TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    INSERT INTO lakets._rollup_registry
        (name, source_chronotable_id, rollup_table, bucket_interval,
         query_text, export_enabled, export_delta_table)
    VALUES (
        '_uc_test_rollup', v_ct_id, '_uc_test_rollup_tbl', '1 hour',
        'SELECT time_bucket(''1 hour'', time) AS bucket, avg(val) FROM _uc_test_metrics GROUP BY 1',
        TRUE, 'main.lakets_test._rollup_uc_test'
    )
    ON CONFLICT (name) DO UPDATE
        SET export_enabled = TRUE,
            export_delta_table = 'main.lakets_test._rollup_uc_test'
    RETURNING id INTO v_rollup_id;

    RAISE NOTICE 'Setup: chronotable_id=%, rollup_id=%', v_ct_id, v_rollup_id;

    -- =========================================================================
    -- T1: register_uc_table creates a registry row
    -- =========================================================================
    SELECT lakets.register_uc_table('_uc_test_rollup', 'main', 'lakets_test') INTO v_reg_id;
    ASSERT v_reg_id IS NOT NULL, 'T1 FAILED: register_uc_table returned NULL id';
    ASSERT EXISTS (
        SELECT 1 FROM lakets._uc_registry
        WHERE rollup_name = '_uc_test_rollup'
          AND uc_catalog = 'main'
          AND uc_schema = 'lakets_test'
    ), 'T1 FAILED: registry row not found';
    RAISE NOTICE 'T1 PASSED: register_uc_table id=%', v_reg_id;

    -- =========================================================================
    -- T2: register_uc_table is idempotent (upsert)
    -- =========================================================================
    DECLARE v_reg_id2 INT;
    BEGIN
        SELECT lakets.register_uc_table('_uc_test_rollup', 'main', 'lakets_test') INTO v_reg_id2;
        ASSERT v_reg_id2 IS NOT NULL, 'T2 FAILED: idempotent call returned NULL';
        SELECT count(*) INTO v_rows
        FROM lakets._uc_registry WHERE rollup_name = '_uc_test_rollup';
        ASSERT v_rows = 1, 'T2 FAILED: expected 1 row, got ' || v_rows;
        RAISE NOTICE 'T2 PASSED: idempotent register ok';
    END;

    -- =========================================================================
    -- T3: register_uc_table fails for unknown rollup
    -- =========================================================================
    BEGIN
        PERFORM lakets.register_uc_table('_nonexistent_rollup', 'main', 'test');
        ASSERT FALSE, 'T3 FAILED: expected exception for unknown rollup';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'T3 PASSED: unknown rollup raises exception: %', SQLERRM;
    END;

    -- =========================================================================
    -- T4: tag_uc_table applies system + user tags and returns merged JSONB
    -- =========================================================================
    SELECT lakets.tag_uc_table('_uc_test_rollup', '{"team": "analytics"}'::jsonb)
    INTO v_tags;
    ASSERT v_tags IS NOT NULL, 'T4 FAILED: tag_uc_table returned NULL';
    ASSERT v_tags ? 'lakets.source',      'T4 FAILED: missing lakets.source tag';
    ASSERT v_tags ? 'lakets.version',     'T4 FAILED: missing lakets.version tag';
    ASSERT v_tags ? 'lakets.rollup_name', 'T4 FAILED: missing lakets.rollup_name tag';
    ASSERT v_tags ? 'team',               'T4 FAILED: missing user-supplied team tag';
    ASSERT v_tags->>'lakets.rollup_name' = '_uc_test_rollup',
        'T4 FAILED: rollup_name tag mismatch';
    ASSERT v_tags->>'team' = 'analytics', 'T4 FAILED: team tag value mismatch';
    RAISE NOTICE 'T4 PASSED: tag_uc_table returned tags: %', v_tags;

    -- =========================================================================
    -- T5: tag_uc_table persists tags and updates last_tagged_at
    -- =========================================================================
    ASSERT EXISTS (
        SELECT 1 FROM lakets._uc_registry
        WHERE rollup_name = '_uc_test_rollup'
          AND last_tagged_at IS NOT NULL
          AND tags ? 'lakets.source'
    ), 'T5 FAILED: tags not persisted in _uc_registry';
    RAISE NOTICE 'T5 PASSED: tags persisted correctly';

    -- =========================================================================
    -- T6: tag_uc_table fails for unregistered rollup
    -- =========================================================================
    BEGIN
        PERFORM lakets.tag_uc_table('_nonexistent_rollup');
        ASSERT FALSE, 'T6 FAILED: expected exception for unregistered rollup';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'T6 PASSED: unregistered rollup raises exception: %', SQLERRM;
    END;

    -- =========================================================================
    -- T7: get_uc_registrations returns the registered row with full_uc_name
    -- =========================================================================
    SELECT count(*) INTO v_rows
    FROM lakets.get_uc_registrations('_uc_test_rollup');
    ASSERT v_rows = 1, 'T7 FAILED: expected 1 row, got ' || v_rows;

    SELECT * INTO v_results
    FROM lakets.get_uc_registrations('_uc_test_rollup')
    LIMIT 1;
    ASSERT v_results.full_uc_name = 'main.lakets_test._rollup_uc_test',
        'T7 FAILED: full_uc_name mismatch: ' || v_results.full_uc_name;
    RAISE NOTICE 'T7 PASSED: get_uc_registrations full_uc_name=%', v_results.full_uc_name;

    -- =========================================================================
    -- T8: get_uc_registrations with NULL returns all rows
    -- =========================================================================
    SELECT count(*) INTO v_rows FROM lakets.get_uc_registrations(NULL);
    ASSERT v_rows >= 1, 'T8 FAILED: expected at least 1 row with NULL filter';
    RAISE NOTICE 'T8 PASSED: get_uc_registrations(NULL) returned % row(s)', v_rows;

    -- =========================================================================
    -- T9: unregister_uc_table removes the registry row
    -- =========================================================================
    DECLARE v_ok BOOLEAN;
    BEGIN
        SELECT lakets.unregister_uc_table('_uc_test_rollup') INTO v_ok;
        ASSERT v_ok = TRUE, 'T9 FAILED: unregister returned FALSE';
        ASSERT NOT EXISTS (
            SELECT 1 FROM lakets._uc_registry WHERE rollup_name = '_uc_test_rollup'
        ), 'T9 FAILED: registry row still exists after unregister';
        RAISE NOTICE 'T9 PASSED: unregister_uc_table removed row';
    END;

    -- =========================================================================
    -- T10: unregister_uc_table returns FALSE for unknown rollup
    -- =========================================================================
    DECLARE v_ok2 BOOLEAN;
    BEGIN
        SELECT lakets.unregister_uc_table('_nonexistent_rollup') INTO v_ok2;
        ASSERT v_ok2 = FALSE, 'T10 FAILED: expected FALSE for unknown rollup';
        RAISE NOTICE 'T10 PASSED: unregister unknown rollup returns FALSE';
    END;

    -- =========================================================================
    -- Cleanup
    -- =========================================================================
    DELETE FROM lakets._uc_registry WHERE rollup_name LIKE '_uc_test%';
    DELETE FROM lakets._rollup_registry WHERE name = '_uc_test_rollup';
    DELETE FROM lakets._chronotable_registry WHERE table_name = '_uc_test_metrics';

    RAISE NOTICE '=== Module 14 UC Integration: all tests PASSED ===';
END $$;
