-- =============================================================================
-- LakeTS Monitoring & Metrics
-- SQL functions that expose operational metrics for Prometheus/Grafana.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- lakets_metrics: Returns all LakeTS operational metrics as key-value rows.
-- Compatible with sql_exporter for Prometheus scraping.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.lakets_metrics()
RETURNS TABLE (
    metric_name TEXT,
    metric_value DOUBLE PRECISION,
    labels JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Hypertable count
    RETURN QUERY
    SELECT 'lakets_hypertables_total'::TEXT, count(*)::DOUBLE PRECISION, '{}'::JSONB
    FROM lakets._chronotable_registry;

    -- Total chunks by status
    RETURN QUERY
    SELECT 'lakets_chunks_total'::TEXT, count(*)::DOUBLE PRECISION,
           jsonb_build_object('status', cm.status)
    FROM lakets._chunk_metadata cm
    GROUP BY cm.status;

    -- Total row estimate per hypertable (from pg_stat)
    RETURN QUERY
    SELECT 'lakets_estimated_rows'::TEXT,
           COALESCE(s.n_live_tup, 0)::DOUBLE PRECISION,
           jsonb_build_object('table', hr.schema_name || '.' || hr.table_name)
    FROM lakets._chronotable_registry hr
    LEFT JOIN pg_stat_user_tables s
        ON s.schemaname = hr.schema_name AND s.relname = hr.table_name;

    -- Tiering: eligible-but-not-yet-dropped chunks per table.
    RETURN QUERY
    SELECT 'lakets_tiering_pending_chunks'::TEXT,
           count(*) FILTER (WHERE cm.status = 'active'
                            AND cm.range_end <= now() - (pr.config->>'after')::INTERVAL)::DOUBLE PRECISION,
           jsonb_build_object('table', hr.schema_name || '.' || hr.table_name)
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id AND pr.policy_type = 'tiering'
    LEFT JOIN lakets._chunk_metadata cm ON cm.chronotable_id = hr.id
    GROUP BY hr.schema_name, hr.table_name;

    -- Tiering: chunks tiered to date per table.
    RETURN QUERY
    SELECT 'lakets_tiering_tiered_chunks_total'::TEXT,
           count(*) FILTER (WHERE cm.status = 'tiered')::DOUBLE PRECISION,
           jsonb_build_object('table', hr.schema_name || '.' || hr.table_name)
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id AND pr.policy_type = 'tiering'
    LEFT JOIN lakets._chunk_metadata cm ON cm.chronotable_id = hr.id
    GROUP BY hr.schema_name, hr.table_name;

    -- Tiering: CDF caught-up flag per table (1 = durability gate currently passes).
    RETURN QUERY
    SELECT 'lakets_tiering_caught_up'::TEXT,
           (CASE WHEN lakets._cdf_committed_lsn(hr.shadow_table_name) >= pg_current_wal_lsn()
                 THEN 1 ELSE 0 END)::DOUBLE PRECISION,
           jsonb_build_object('table', hr.schema_name || '.' || hr.table_name)
    FROM lakets._chronotable_registry hr
    JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id AND pr.policy_type = 'tiering';

    -- RollUp watermark lag (seconds between now and watermark per RollUp)
    RETURN QUERY
    SELECT 'lakets_rollup_watermark_lag_seconds'::TEXT,
           EXTRACT(EPOCH FROM (now() - r.watermark))::DOUBLE PRECISION,
           jsonb_build_object('rollup', r.name)
    FROM lakets._rollup_registry r
    WHERE r.watermark IS NOT NULL;

    -- RollUp refresh lag (seconds since last refresh)
    RETURN QUERY
    SELECT 'lakets_rollup_refresh_lag_seconds'::TEXT,
           EXTRACT(EPOCH FROM (now() - r.last_refreshed_at))::DOUBLE PRECISION,
           jsonb_build_object('rollup', r.name)
    FROM lakets._rollup_registry r
    WHERE r.last_refreshed_at IS NOT NULL;

    -- RollUp invalidation log depth (pending dirty buckets per RollUp by tier)
    RETURN QUERY
    SELECT 'lakets_rollup_invalidation_log_depth'::TEXT,
           count(*)::DOUBLE PRECISION,
           jsonb_build_object('rollup', r.name, 'tier', il.tier)
    FROM lakets._rollup_invalidation_log il
    JOIN lakets._rollup_registry r ON il.rollup_id = r.id
    GROUP BY r.name, il.tier;

    -- Sync status per hypertable
    RETURN QUERY
    SELECT 'lakets_sync_enabled'::TEXT,
           (CASE WHEN hr.sync_enabled THEN 1 ELSE 0 END)::DOUBLE PRECISION,
           jsonb_build_object('table', hr.schema_name || '.' || hr.table_name)
    FROM lakets._chronotable_registry hr;

    -- Policy count by type
    RETURN QUERY
    SELECT 'lakets_policies_total'::TEXT, count(*)::DOUBLE PRECISION,
           jsonb_build_object('type', pr.policy_type)
    FROM lakets._policy_registry pr
    WHERE pr.enabled = TRUE
    GROUP BY pr.policy_type;

    -- Database size
    RETURN QUERY
    SELECT 'lakets_database_size_bytes'::TEXT,
           pg_database_size(current_database())::DOUBLE PRECISION,
           '{}'::JSONB;
END;
$$;

-- ---------------------------------------------------------------------------
-- chunk_health: Detailed per-hypertable chunk health report.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.chunk_health()
RETURNS TABLE (
    hypertable TEXT,
    total_chunks BIGINT,
    active_chunks BIGINT,
    tiered_chunks BIGINT,
    dropped_chunks BIGINT,
    oldest_active TIMESTAMPTZ,
    newest_active TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        hr.schema_name || '.' || hr.table_name,
        count(*)::BIGINT,
        count(*) FILTER (WHERE cm.status = 'active')::BIGINT,
        count(*) FILTER (WHERE cm.status = 'tiered')::BIGINT,
        count(*) FILTER (WHERE cm.status = 'dropped')::BIGINT,
        min(cm.range_start) FILTER (WHERE cm.status = 'active'),
        max(cm.range_end) FILTER (WHERE cm.status = 'active')
    FROM lakets._chronotable_registry hr
    JOIN lakets._chunk_metadata cm ON hr.id = cm.chronotable_id
    GROUP BY hr.schema_name, hr.table_name
    ORDER BY hr.schema_name, hr.table_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- query_stats: Wraps pg_stat_statements for LakeTS-relevant queries.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.query_stats(p_limit INT DEFAULT 20)
RETURNS TABLE (
    query TEXT,
    calls BIGINT,
    total_time_ms DOUBLE PRECISION,
    mean_time_ms DOUBLE PRECISION,
    rows_returned BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- pg_stat_statements may not be available; handle gracefully
    BEGIN
        RETURN QUERY EXECUTE format(
            'SELECT left(query, 200), calls, total_exec_time, mean_exec_time, rows
             FROM pg_stat_statements
             WHERE query LIKE ''%%lakets%%'' OR query LIKE ''%%time_bucket%%''
             ORDER BY total_exec_time DESC
             LIMIT %s', p_limit
        );
    EXCEPTION WHEN undefined_table THEN
        -- pg_stat_statements not available
        RETURN;
    END;
END;
$$;
