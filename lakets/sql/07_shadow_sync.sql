-- =============================================================================
-- LakeTS Shadow Sync
-- Shadow table + trigger pattern for Lakehouse Sync (wal2delta CDC).
-- Required because Lakehouse Sync does not support partitioned tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- _sync_trigger_fn: Trigger function that forwards writes to shadow table.
-- Dynamically routes based on TG_TABLE_SCHEMA and TG_TABLE_NAME.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._sync_trigger_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_shadow TEXT;
    v_parent TEXT;
BEGIN
    -- For partitioned tables, TG_TABLE_NAME is the partition name.
    -- Look up the parent table to find the shadow table name.
    SELECT p.relname INTO v_parent
    FROM pg_inherits i
    JOIN pg_class c ON i.inhrelid = c.oid
    JOIN pg_class p ON i.inhparent = p.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = TG_TABLE_SCHEMA AND c.relname = TG_TABLE_NAME
    LIMIT 1;

    SELECT shadow_table_name INTO v_shadow
    FROM lakets._chronotable_registry
    WHERE schema_name = TG_TABLE_SCHEMA
      AND table_name = COALESCE(v_parent, TG_TABLE_NAME);

    IF v_shadow IS NULL THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        EXECUTE format('INSERT INTO %I.%I SELECT ($1).*', TG_TABLE_SCHEMA, v_shadow)
        USING OLD;
        RETURN OLD;
    ELSE
        EXECUTE format('INSERT INTO %I.%I SELECT ($1).*', TG_TABLE_SCHEMA, v_shadow)
        USING NEW;
        RETURN NEW;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- enable_sync: Creates shadow table and trigger for Lakehouse Sync.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.enable_sync(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_shadow_name TEXT;
    v_col_rec RECORD;
    v_col_defs TEXT := '';
    v_time_col TEXT;
BEGIN
    SELECT id, time_column INTO v_chronotable_id, v_time_col
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    v_shadow_name := '_shadow_' || p_table_name;

    -- Build column definitions from the partitioned table
    FOR v_col_rec IN
        SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod) as col_type,
               a.attnotnull
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema_name AND c.relname = p_table_name
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF v_col_defs != '' THEN v_col_defs := v_col_defs || ', '; END IF;
        v_col_defs := v_col_defs || format('%I %s', v_col_rec.attname, v_col_rec.col_type);
        IF v_col_rec.attnotnull THEN
            v_col_defs := v_col_defs || ' NOT NULL';
        END IF;
    END LOOP;

    -- Create shadow table (unpartitioned)
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I (%s)',
        p_schema_name, v_shadow_name, v_col_defs);

    -- Set REPLICA IDENTITY FULL for CDC capture
    EXECUTE format('ALTER TABLE %I.%I REPLICA IDENTITY FULL',
        p_schema_name, v_shadow_name);

    -- Create trigger on the partitioned parent table
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_sync
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._sync_trigger_fn()',
        p_schema_name, p_table_name
    );

    -- Update registry
    UPDATE lakets._chronotable_registry
    SET shadow_table_name = v_shadow_name,
        sync_enabled = TRUE
    WHERE id = v_chronotable_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- disable_sync: Removes shadow table and trigger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.disable_sync(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_chronotable_id INT;
    v_shadow_name TEXT;
BEGIN
    SELECT id, shadow_table_name INTO v_chronotable_id, v_shadow_name
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not a registered ChronoTable',
            p_schema_name, p_table_name;
    END IF;

    -- Drop trigger
    EXECUTE format(
        'DROP TRIGGER IF EXISTS trg_lakets_sync ON %I.%I',
        p_schema_name, p_table_name
    );

    -- Drop shadow table
    IF v_shadow_name IS NOT NULL THEN
        EXECUTE format('DROP TABLE IF EXISTS %I.%I', p_schema_name, v_shadow_name);
    END IF;

    -- Update registry
    UPDATE lakets._chronotable_registry
    SET shadow_table_name = NULL,
        sync_enabled = FALSE
    WHERE id = v_chronotable_id;
END;
$$;
