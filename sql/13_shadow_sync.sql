-- =============================================================================
-- LakeTS Shadow Sync
-- Shadow table + trigger pattern for Lakehouse Sync (wal2delta CDC).
-- Required because Lakehouse Sync does not support partitioned tables.
-- =============================================================================

-- Sync bookkeeping columns on the RollUp registry (ChronoTable registry already has them).
ALTER TABLE lakets._rollup_registry
    ADD COLUMN IF NOT EXISTS sync_enabled      BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS shadow_table_name TEXT;

-- ---------------------------------------------------------------------------
-- _sync_trigger_fn: true-mirror trigger that forwards writes to the shadow
-- table in lakets_cdf. Dispatches via dual-registry shadow lookup:
--   1. ChronoTable registry (keyed on schema + parent/table name)
--   2. RollUp registry (keyed on physical rollup table name)
-- INSERT → INSERT into shadow
-- UPDATE → DELETE matching old row + INSERT new row into shadow
-- DELETE → DELETE matching row from shadow
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._sync_trigger_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_shadow TEXT;
    v_parent TEXT;
BEGIN
    -- Partition parent (NULL for unpartitioned tables such as RollUps)
    SELECT lakets._resolve_partition_parent(TG_TABLE_SCHEMA, TG_TABLE_NAME) INTO v_parent;

    -- ChronoTable shadow (keyed on parent/table name)
    SELECT shadow_table_name INTO v_shadow
    FROM lakets._chronotable_registry
    WHERE schema_name = TG_TABLE_SCHEMA
      AND table_name = COALESCE(v_parent, TG_TABLE_NAME)
      AND sync_enabled = TRUE;

    -- RollUp shadow (keyed on physical rollup table name)
    IF v_shadow IS NULL THEN
        SELECT shadow_table_name INTO v_shadow
        FROM lakets._rollup_registry
        WHERE rollup_table = TG_TABLE_NAME AND sync_enabled = TRUE;
    END IF;

    IF v_shadow IS NULL THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        EXECUTE format(
            'DELETE FROM lakets_cdf.%I t WHERE ROW(t.*) IS NOT DISTINCT FROM ROW(($1).*)',
            v_shadow) USING OLD;
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        EXECUTE format(
            'DELETE FROM lakets_cdf.%I t WHERE ROW(t.*) IS NOT DISTINCT FROM ROW(($1).*)',
            v_shadow) USING OLD;
        EXECUTE format('INSERT INTO lakets_cdf.%I SELECT ($1).*', v_shadow) USING NEW;
        RETURN NEW;
    ELSE  -- INSERT
        EXECUTE format('INSERT INTO lakets_cdf.%I SELECT ($1).*', v_shadow) USING NEW;
        RETURN NEW;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- _build_shadow_table: create an unpartitioned shadow in lakets_cdf mirroring
-- the source columns, with REPLICA IDENTITY FULL for CDC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._build_shadow_table(
    p_src_schema TEXT, p_src_table TEXT, p_shadow_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_col_rec RECORD;
    v_col_defs TEXT := '';
BEGIN
    FOR v_col_rec IN
        SELECT a.attname,
               pg_catalog.format_type(a.atttypid, a.atttypmod) AS col_type,
               a.attnotnull
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_src_schema AND c.relname = p_src_table
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF v_col_defs <> '' THEN v_col_defs := v_col_defs || ', '; END IF;
        v_col_defs := v_col_defs || format('%I %s', v_col_rec.attname, v_col_rec.col_type);
        IF v_col_rec.attnotnull THEN
            v_col_defs := v_col_defs || ' NOT NULL';
        END IF;
    END LOOP;

    EXECUTE format('CREATE TABLE IF NOT EXISTS lakets_cdf.%I (%s)', p_shadow_name, v_col_defs);
    EXECUTE format('ALTER TABLE lakets_cdf.%I REPLICA IDENTITY FULL', p_shadow_name);
END;
$$;

-- ---------------------------------------------------------------------------
-- enable_sync: dispatch by table type (ChronoTable path or RollUp path).
-- Accepts either a ChronoTable name (schema+table) or a RollUp name.
-- Raises on ambiguous or unknown input.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.enable_sync(
    p_table_name TEXT, p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_ct BOOLEAN;
    v_is_ru BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM lakets._chronotable_registry
                  WHERE schema_name = p_schema_name AND table_name = p_table_name) INTO v_is_ct;
    SELECT EXISTS(SELECT 1 FROM lakets._rollup_registry WHERE name = p_table_name) INTO v_is_ru;

    IF v_is_ct AND v_is_ru THEN
        RAISE EXCEPTION 'Ambiguous: % is both a ChronoTable and a RollUp', p_table_name;
    ELSIF v_is_ct THEN
        PERFORM lakets._enable_chronotable_sync(p_table_name, p_schema_name);
    ELSIF v_is_ru THEN
        PERFORM lakets._enable_rollup_sync(p_table_name);
    ELSE
        RAISE EXCEPTION '% is not a registered ChronoTable or RollUp', p_table_name;
    END IF;
END;
$$;

-- _enable_chronotable_sync: shadow in lakets_cdf + trigger on the partitioned parent.
CREATE OR REPLACE FUNCTION lakets._enable_chronotable_sync(
    p_table_name TEXT, p_schema_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_id INT; v_already BOOLEAN; v_shadow TEXT;
BEGIN
    SELECT id, sync_enabled INTO v_id, v_already
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF v_already THEN
        RAISE NOTICE 'ChronoTable %.% is already synced', p_schema_name, p_table_name;
        RETURN;
    END IF;

    v_shadow := '_shadow_' || p_table_name;
    PERFORM lakets._build_shadow_table(p_schema_name, p_table_name, v_shadow);

    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_sync
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._sync_trigger_fn()',
        p_schema_name, p_table_name);

    UPDATE lakets._chronotable_registry
    SET shadow_table_name = v_shadow, sync_enabled = TRUE
    WHERE id = v_id;
END;
$$;

-- _enable_rollup_sync: shadow in lakets_cdf + trigger on the unpartitioned rollup table.
CREATE OR REPLACE FUNCTION lakets._enable_rollup_sync(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_rollup_table TEXT; v_already BOOLEAN; v_shadow TEXT;
BEGIN
    SELECT rollup_table, sync_enabled INTO v_rollup_table, v_already
    FROM lakets._rollup_registry WHERE name = p_rollup_name;

    IF v_already THEN
        RAISE NOTICE 'RollUp % is already synced', p_rollup_name;
        RETURN;
    END IF;

    v_shadow := '_shadow_rollup_' || p_rollup_name;
    PERFORM lakets._build_shadow_table('public', v_rollup_table, v_shadow);

    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_sync
         AFTER INSERT OR UPDATE OR DELETE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._sync_trigger_fn()',
        v_rollup_table);

    UPDATE lakets._rollup_registry
    SET shadow_table_name = v_shadow, sync_enabled = TRUE
    WHERE name = p_rollup_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- disable_sync: dispatch by table type; tears down shadow + trigger + flag.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.disable_sync(
    p_table_name TEXT, p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_is_ct BOOLEAN; v_is_ru BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM lakets._chronotable_registry
                  WHERE schema_name = p_schema_name AND table_name = p_table_name) INTO v_is_ct;
    SELECT EXISTS(SELECT 1 FROM lakets._rollup_registry WHERE name = p_table_name) INTO v_is_ru;

    IF v_is_ct AND v_is_ru THEN
        RAISE EXCEPTION 'Ambiguous: % is both a ChronoTable and a RollUp', p_table_name;
    ELSIF v_is_ct THEN
        PERFORM lakets._disable_chronotable_sync(p_table_name, p_schema_name);
    ELSIF v_is_ru THEN
        PERFORM lakets._disable_rollup_sync(p_table_name);
    ELSE
        RAISE EXCEPTION '% is not a registered ChronoTable or RollUp', p_table_name;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION lakets._disable_chronotable_sync(
    p_table_name TEXT, p_schema_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_id INT; v_shadow TEXT; v_sync BOOLEAN;
BEGIN
    SELECT id, shadow_table_name, sync_enabled INTO v_id, v_shadow, v_sync
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT COALESCE(v_sync, FALSE) THEN
        RAISE NOTICE 'ChronoTable %.% is not synced', p_schema_name, p_table_name;
        RETURN;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_sync ON %I.%I', p_schema_name, p_table_name);
    IF v_shadow IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS lakets_cdf.%I', v_shadow);
    END IF;
    UPDATE lakets._chronotable_registry
    SET shadow_table_name = NULL, sync_enabled = FALSE WHERE id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION lakets._disable_rollup_sync(p_rollup_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE v_rollup_table TEXT; v_shadow TEXT; v_sync BOOLEAN;
BEGIN
    SELECT rollup_table, shadow_table_name, sync_enabled INTO v_rollup_table, v_shadow, v_sync
    FROM lakets._rollup_registry WHERE name = p_rollup_name;

    IF NOT COALESCE(v_sync, FALSE) THEN
        RAISE NOTICE 'RollUp % is not synced', p_rollup_name;
        RETURN;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_sync ON public.%I', v_rollup_table);
    IF v_shadow IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS lakets_cdf.%I', v_shadow);
    END IF;
    UPDATE lakets._rollup_registry
    SET shadow_table_name = NULL, sync_enabled = FALSE WHERE name = p_rollup_name;
END;
$$;
