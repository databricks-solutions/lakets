-- =============================================================================
-- LakeTS Alert Rules
-- SQL-native alerting on hot Lakebase data.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- alert_check: Runs a query and returns rows that match alert conditions.
-- The query should return rows that are "firing" (e.g., WHERE cpu > 90).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.alert_check(
    p_name TEXT,
    p_query TEXT,
    p_severity TEXT DEFAULT 'warning'
)
RETURNS TABLE (
    alert_name TEXT,
    severity TEXT,
    fired_at TIMESTAMPTZ,
    alert_data JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row RECORD;
BEGIN
    FOR v_row IN EXECUTE p_query LOOP
        alert_name := p_name;
        severity := p_severity;
        fired_at := now();
        alert_data := to_jsonb(v_row);
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- alert_deadman: Detects series that haven't reported data within timeout.
-- Returns group keys that are "dead" (no data for > timeout).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.alert_deadman(
    p_name TEXT,
    p_table_name TEXT,
    p_group_by TEXT,
    p_timeout INTERVAL,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TABLE (
    alert_name TEXT,
    severity TEXT,
    fired_at TIMESTAMPTZ,
    dead_key TEXT,
    last_seen TIMESTAMPTZ,
    silent_for INTERVAL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_time_col TEXT;
BEGIN
    SELECT time_column INTO v_time_col
    FROM lakets._chronotable_registry
    WHERE schema_name = p_schema_name AND table_name = p_table_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION '%.% is not a registered ChronoTable', p_schema_name, p_table_name;
    END IF;

    -- Validate p_group_by is a simple column name to prevent SQL injection
    IF p_group_by !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'p_group_by must be a simple column name, got: %', p_group_by;
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT %L::TEXT, ''critical''::TEXT, now(),
                %I::TEXT, max(%I), now() - max(%I)
         FROM %I.%I
         GROUP BY %I
         HAVING max(%I) < now() - %L::INTERVAL',
        p_name, p_group_by, v_time_col, v_time_col,
        p_schema_name, p_table_name,
        p_group_by, v_time_col, p_timeout::TEXT
    );
END;
$$;
