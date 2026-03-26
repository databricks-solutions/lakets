-- =============================================================================
-- LakeTS Last Value Cache (LVC)
-- Trigger-maintained cache for sub-10ms latest-state queries.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- _lvc_trigger_fn: Generic trigger that upserts into the LVC cache table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets._lvc_trigger_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cache_table TEXT;
    v_key_cols TEXT[];
    v_val_cols TEXT[];
    v_set_clause TEXT := '';
    v_ins_cols TEXT := '';
    v_ins_vals TEXT := '';
    v_col TEXT;
BEGIN
    -- Look up the LVC config from registry via parent table resolution
    SELECT lr.cache_table_name, lr.key_columns, lr.value_columns
    INTO v_cache_table, v_key_cols, v_val_cols
    FROM lakets._lvc_registry lr
    JOIN lakets._chronotable_registry hr ON lr.chronotable_id = hr.id
    WHERE hr.table_name = COALESCE(
        (SELECT p.relname FROM pg_inherits i
         JOIN pg_class ch ON i.inhrelid = ch.oid
         JOIN pg_class p ON i.inhparent = p.oid
         JOIN pg_namespace n ON ch.relnamespace = n.oid
         WHERE n.nspname = TG_TABLE_SCHEMA AND ch.relname = TG_TABLE_NAME
         LIMIT 1),
        TG_TABLE_NAME
    ) AND hr.schema_name = TG_TABLE_SCHEMA;

    IF v_cache_table IS NULL THEN
        RETURN NEW;
    END IF;

    -- Build column lists: only key + value columns (not all source columns)
    FOREACH v_col IN ARRAY v_key_cols LOOP
        IF v_ins_cols != '' THEN v_ins_cols := v_ins_cols || ', '; v_ins_vals := v_ins_vals || ', '; END IF;
        v_ins_cols := v_ins_cols || format('%I', v_col);
        v_ins_vals := v_ins_vals || format('($1).%I', v_col);
    END LOOP;

    FOREACH v_col IN ARRAY v_val_cols LOOP
        IF v_ins_cols != '' THEN v_ins_cols := v_ins_cols || ', '; v_ins_vals := v_ins_vals || ', '; END IF;
        v_ins_cols := v_ins_cols || format('%I', v_col);
        v_ins_vals := v_ins_vals || format('($1).%I', v_col);
        IF v_set_clause != '' THEN v_set_clause := v_set_clause || ', '; END IF;
        v_set_clause := v_set_clause || format('%I = EXCLUDED.%I', v_col, v_col);
    END LOOP;

    v_ins_cols := v_ins_cols || ', last_updated';
    v_ins_vals := v_ins_vals || ', now()';
    v_set_clause := v_set_clause || ', last_updated = now()';

    -- UPSERT into cache (only key + value columns)
    EXECUTE format(
        'INSERT INTO %I.%I (%s) VALUES (%s) ON CONFLICT (%s) DO UPDATE SET %s',
        TG_TABLE_SCHEMA, v_cache_table,
        v_ins_cols, v_ins_vals,
        array_to_string(v_key_cols, ', '), v_set_clause
    ) USING NEW;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- enable_lvc: Creates a cache table + trigger for a ChronoTable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.enable_lvc(
    p_table_name TEXT,
    p_key_columns TEXT[],
    p_value_columns TEXT[],
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_ht_id INT;
    v_cache_name TEXT;
    v_col_defs TEXT := '';
    v_col TEXT;
    v_col_type TEXT;
BEGIN
    SELECT id INTO v_ht_id FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION '%.% is not a registered ChronoTable', p_schema_name, p_table_name;
    END IF;

    IF EXISTS (SELECT 1 FROM lakets._lvc_registry WHERE chronotable_id = v_ht_id) THEN
        RAISE EXCEPTION 'LVC already enabled for %.%', p_schema_name, p_table_name;
    END IF;

    v_cache_name := '_lvc_' || p_table_name;

    -- Build cache table: key columns + value columns + last_updated
    FOREACH v_col IN ARRAY p_key_columns LOOP
        SELECT format_type(a.atttypid, a.atttypmod) INTO v_col_type
        FROM pg_attribute a JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema_name AND c.relname = p_table_name AND a.attname = v_col;
        v_col_defs := v_col_defs || format('%I %s NOT NULL, ', v_col, v_col_type);
    END LOOP;

    FOREACH v_col IN ARRAY p_value_columns LOOP
        SELECT format_type(a.atttypid, a.atttypmod) INTO v_col_type
        FROM pg_attribute a JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = p_schema_name AND c.relname = p_table_name AND a.attname = v_col;
        v_col_defs := v_col_defs || format('%I %s, ', v_col, v_col_type);
    END LOOP;

    v_col_defs := v_col_defs || 'last_updated TIMESTAMPTZ NOT NULL DEFAULT now()';

    -- Create cache table with PK on key columns
    EXECUTE format('CREATE TABLE %I.%I (%s, PRIMARY KEY (%s))',
        p_schema_name, v_cache_name, v_col_defs,
        array_to_string(p_key_columns, ', '));

    -- Create trigger on ChronoTable
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_lakets_lvc AFTER INSERT ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION lakets._lvc_trigger_fn()',
        p_schema_name, p_table_name
    );

    -- Register in LVC registry
    INSERT INTO lakets._lvc_registry (chronotable_id, cache_table_name, key_columns, value_columns)
    VALUES (v_ht_id, v_cache_name, p_key_columns, p_value_columns);
END;
$$;

-- ---------------------------------------------------------------------------
-- disable_lvc: Removes cache table and trigger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.disable_lvc(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_ht_id INT;
    v_cache_name TEXT;
BEGIN
    SELECT hr.id, lr.cache_table_name INTO v_ht_id, v_cache_name
    FROM lakets._chronotable_registry hr
    JOIN lakets._lvc_registry lr ON hr.id = lr.chronotable_id
    WHERE hr.schema_name = p_schema_name AND hr.table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LVC not enabled for %.%', p_schema_name, p_table_name;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS trg_lakets_lvc ON %I.%I', p_schema_name, p_table_name);
    EXECUTE format('DROP TABLE IF EXISTS %I.%I', p_schema_name, v_cache_name);
    DELETE FROM lakets._lvc_registry WHERE chronotable_id = v_ht_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- latest_values: Reads from LVC cache table. Sub-10ms.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.latest_values(
    p_table_name TEXT,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS SETOF RECORD
LANGUAGE plpgsql
AS $$
DECLARE
    v_cache_name TEXT;
BEGIN
    SELECT lr.cache_table_name INTO v_cache_name
    FROM lakets._chronotable_registry hr
    JOIN lakets._lvc_registry lr ON hr.id = lr.chronotable_id
    WHERE hr.schema_name = p_schema_name AND hr.table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LVC not enabled for %.%', p_schema_name, p_table_name;
    END IF;

    RETURN QUERY EXECUTE format('SELECT * FROM %I.%I ORDER BY last_updated DESC',
        p_schema_name, v_cache_name);
END;
$$;

-- ---------------------------------------------------------------------------
-- lvc_stats: Cache statistics across all LVC-enabled tables.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.lvc_stats()
RETURNS TABLE (
    chronotable TEXT,
    cache_table TEXT,
    cached_series BIGINT,
    key_columns TEXT,
    value_columns TEXT,
    enabled BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_count BIGINT;
BEGIN
    FOR v_rec IN
        SELECT hr.schema_name, hr.table_name, lr.cache_table_name,
               lr.key_columns, lr.value_columns, lr.enabled
        FROM lakets._lvc_registry lr
        JOIN lakets._chronotable_registry hr ON lr.chronotable_id = hr.id
    LOOP
        BEGIN
            EXECUTE format('SELECT count(*) FROM %I.%I',
                v_rec.schema_name, v_rec.cache_table_name) INTO v_count;
        EXCEPTION WHEN OTHERS THEN
            v_count := 0;
        END;

        chronotable := v_rec.schema_name || '.' || v_rec.table_name;
        cache_table := v_rec.cache_table_name;
        cached_series := v_count;
        key_columns := array_to_string(v_rec.key_columns, ', ');
        value_columns := array_to_string(v_rec.value_columns, ', ');
        enabled := v_rec.enabled;
        RETURN NEXT;
    END LOOP;
END;
$$;
