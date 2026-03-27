-- =============================================================================
-- LakeTS Time Series Functions
-- Time series analytical functions: time_bucket, first, last,
-- time_bucket_gapfill, locf, interpolate, delta, rate, histogram.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- time_bucket: Truncates a timestamp to the nearest bucket boundary.
-- For sub-month intervals, delegates to date_bin.
-- For month/year intervals, uses date_trunc + interval math.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.time_bucket(
    p_interval INTERVAL,
    p_timestamp TIMESTAMPTZ,
    p_origin TIMESTAMPTZ DEFAULT '2000-01-01 00:00:00+00'::timestamptz
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_months INT;
BEGIN
    -- Extract months component (for month/year intervals)
    v_months := EXTRACT(YEAR FROM p_interval)::INT * 12
                + EXTRACT(MONTH FROM p_interval)::INT;

    IF v_months > 0 THEN
        -- Month-based bucketing: truncate to month, then align to interval
        DECLARE
            v_origin_months INT;
            v_ts_months INT;
            v_bucket_months INT;
        BEGIN
            v_origin_months := EXTRACT(YEAR FROM p_origin)::INT * 12
                               + EXTRACT(MONTH FROM p_origin)::INT - 1;
            v_ts_months := EXTRACT(YEAR FROM p_timestamp)::INT * 12
                           + EXTRACT(MONTH FROM p_timestamp)::INT - 1;
            v_bucket_months := v_origin_months
                               + ((v_ts_months - v_origin_months) / v_months) * v_months;
            RETURN make_timestamptz(
                v_bucket_months / 12,
                (v_bucket_months % 12) + 1,
                1, 0, 0, 0
            );
        END;
    ELSE
        -- Sub-month intervals: use native date_bin
        RETURN date_bin(p_interval, p_timestamp, p_origin);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- first: Aggregate that returns the value associated with the earliest time.
-- ---------------------------------------------------------------------------

-- State type for first/last aggregates (idempotent: drop + recreate)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid
               WHERE n.nspname = 'lakets' AND t.typname = '_first_last_state') THEN
        -- Drop dependents first, they'll be recreated below
        DROP AGGREGATE IF EXISTS lakets.first(DOUBLE PRECISION, TIMESTAMPTZ);
        DROP AGGREGATE IF EXISTS lakets.last(DOUBLE PRECISION, TIMESTAMPTZ);
        DROP FUNCTION IF EXISTS lakets._first_ffunc(lakets._first_last_state);
        DROP FUNCTION IF EXISTS lakets._last_ffunc(lakets._first_last_state);
        DROP FUNCTION IF EXISTS lakets._first_sfunc(lakets._first_last_state, DOUBLE PRECISION, TIMESTAMPTZ);
        DROP FUNCTION IF EXISTS lakets._last_sfunc(lakets._first_last_state, DOUBLE PRECISION, TIMESTAMPTZ);
        DROP TYPE lakets._first_last_state;
    END IF;
END $$;
CREATE TYPE lakets._first_last_state AS (
    value DOUBLE PRECISION,
    ts TIMESTAMPTZ
);

-- State transition: keep the row with the earliest timestamp
CREATE OR REPLACE FUNCTION lakets._first_sfunc(
    state lakets._first_last_state,
    value DOUBLE PRECISION,
    ts TIMESTAMPTZ
)
RETURNS lakets._first_last_state
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF state IS NULL OR state.ts IS NULL THEN
        RETURN ROW(value, ts)::lakets._first_last_state;
    END IF;
    IF ts < state.ts THEN
        RETURN ROW(value, ts)::lakets._first_last_state;
    END IF;
    RETURN state;
END;
$$;

-- Final function: extract the value
CREATE OR REPLACE FUNCTION lakets._first_ffunc(state lakets._first_last_state)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN state.value;
END;
$$;

-- Create the aggregate
DROP AGGREGATE IF EXISTS lakets.first(DOUBLE PRECISION, TIMESTAMPTZ);
CREATE AGGREGATE lakets.first(DOUBLE PRECISION, TIMESTAMPTZ) (
    SFUNC = lakets._first_sfunc,
    STYPE = lakets._first_last_state,
    FINALFUNC = lakets._first_ffunc
);

-- ---------------------------------------------------------------------------
-- last: Aggregate that returns the value associated with the latest time.
-- ---------------------------------------------------------------------------

-- State transition: keep the row with the latest timestamp
CREATE OR REPLACE FUNCTION lakets._last_sfunc(
    state lakets._first_last_state,
    value DOUBLE PRECISION,
    ts TIMESTAMPTZ
)
RETURNS lakets._first_last_state
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF state IS NULL OR state.ts IS NULL THEN
        RETURN ROW(value, ts)::lakets._first_last_state;
    END IF;
    IF ts > state.ts THEN
        RETURN ROW(value, ts)::lakets._first_last_state;
    END IF;
    RETURN state;
END;
$$;

-- Final function: extract the value
CREATE OR REPLACE FUNCTION lakets._last_ffunc(state lakets._first_last_state)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN state.value;
END;
$$;

-- Create the aggregate
DROP AGGREGATE IF EXISTS lakets.last(DOUBLE PRECISION, TIMESTAMPTZ);
CREATE AGGREGATE lakets.last(DOUBLE PRECISION, TIMESTAMPTZ) (
    SFUNC = lakets._last_sfunc,
    STYPE = lakets._first_last_state,
    FINALFUNC = lakets._last_ffunc
);

-- ===========================================================================
-- PHASE 2: Advanced Time Series Functions
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- time_bucket_gapfill: Returns a set of time buckets between start and finish,
-- filling gaps where no data exists. Use with LEFT JOIN to get gapfilled series.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.time_bucket_gapfill(
    p_interval INTERVAL,
    p_start TIMESTAMPTZ,
    p_finish TIMESTAMPTZ
)
RETURNS SETOF TIMESTAMPTZ
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT generate_series(
        lakets.time_bucket(p_interval, p_start),
        lakets.time_bucket(p_interval, p_finish),
        p_interval
    );
$$;

-- ---------------------------------------------------------------------------
-- locf: Last Observation Carried Forward.
-- Fills NULL values with the most recent non-NULL value in window order.
-- Usage: lakets.locf(value) OVER (PARTITION BY device ORDER BY time)
-- Note: This is a wrapper — must be called within a window context via a
-- helper query pattern since PG doesn't allow window in function body.
-- We provide a table-returning helper instead.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.locf(
    p_value DOUBLE PRECISION,
    p_prev_value DOUBLE PRECISION DEFAULT NULL
)
RETURNS DOUBLE PRECISION
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT COALESCE(p_value, p_prev_value);
$$;

-- ---------------------------------------------------------------------------
-- interpolate: Linear interpolation between two known values.
-- Given a NULL value, computes the interpolated value based on the
-- previous and next known values and their timestamps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.interpolate(
    p_value DOUBLE PRECISION,
    p_prev_value DOUBLE PRECISION,
    p_next_value DOUBLE PRECISION,
    p_prev_time TIMESTAMPTZ,
    p_curr_time TIMESTAMPTZ,
    p_next_time TIMESTAMPTZ
)
RETURNS DOUBLE PRECISION
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_value IS NOT NULL THEN p_value
        WHEN p_prev_value IS NULL OR p_next_value IS NULL THEN NULL
        WHEN p_next_time = p_prev_time THEN p_prev_value
        ELSE p_prev_value + (p_next_value - p_prev_value)
             * EXTRACT(EPOCH FROM (p_curr_time - p_prev_time))
             / EXTRACT(EPOCH FROM (p_next_time - p_prev_time))
    END;
$$;

-- ---------------------------------------------------------------------------
-- delta: Computes the difference between consecutive values.
-- Handles counter resets (where value drops below previous).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.delta(
    p_value DOUBLE PRECISION,
    p_prev_value DOUBLE PRECISION,
    p_handle_resets BOOLEAN DEFAULT TRUE
)
RETURNS DOUBLE PRECISION
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_prev_value IS NULL THEN NULL
        WHEN p_handle_resets AND p_value < p_prev_value THEN p_value
        ELSE p_value - p_prev_value
    END;
$$;

-- ---------------------------------------------------------------------------
-- rate: Computes rate of change per second between consecutive points.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.rate(
    p_value DOUBLE PRECISION,
    p_prev_value DOUBLE PRECISION,
    p_time TIMESTAMPTZ,
    p_prev_time TIMESTAMPTZ,
    p_handle_resets BOOLEAN DEFAULT TRUE
)
RETURNS DOUBLE PRECISION
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_prev_value IS NULL OR p_prev_time IS NULL THEN NULL
        WHEN p_time = p_prev_time THEN NULL
        ELSE lakets.delta(p_value, p_prev_value, p_handle_resets)
             / EXTRACT(EPOCH FROM (p_time - p_prev_time))
    END;
$$;

-- ---------------------------------------------------------------------------
-- histogram: Returns a frequency distribution of values as an integer array.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lakets.histogram(
    p_value DOUBLE PRECISION,
    p_min DOUBLE PRECISION,
    p_max DOUBLE PRECISION,
    p_num_buckets INT
)
RETURNS INT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_value IS NULL THEN NULL
        WHEN p_value < p_min THEN 0
        WHEN p_value >= p_max THEN p_num_buckets - 1
        ELSE LEAST(
            FLOOR((p_value - p_min) / ((p_max - p_min) / p_num_buckets))::INT,
            p_num_buckets - 1
        )
    END;
$$;
