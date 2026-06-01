---
title: Time-series functions
sidebar_label: Time-series functions
sidebar_position: 2
description: Analytical functions — time_bucket, first, last, gap-fill, locf, interpolate, delta, rate, histogram.
---

# Time-series functions

Core analytical functions for time-series computation. All are `IMMUTABLE` — safe for use in indexes, generated columns, and parallel queries.

## `time_bucket(p_interval, p_timestamp, p_origin)`

The foundational time-series function. Truncates a timestamp to the nearest bucket boundary aligned to an origin point.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_interval` | INTERVAL | — | Bucket width (e.g., `'1 hour'`, `'5 minutes'`, `'1 month'`) |
| `p_timestamp` | TIMESTAMPTZ | — | Timestamp to bucket |
| `p_origin` | TIMESTAMPTZ | `'2000-01-01 00:00:00+00'` | Alignment origin |

**Returns**: `TIMESTAMPTZ`

**Implementation details**:
- Sub-month intervals (seconds, minutes, hours, days, weeks): delegates to PostgreSQL's `date_bin()` for nanosecond precision
- Month/year intervals: uses `date_trunc` + interval arithmetic to handle variable-length months

```sql
-- Hourly buckets
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       avg(temperature) AS avg_temp
FROM sensor_data
WHERE time >= now() - interval '7 days'
GROUP BY 1 ORDER BY 1;

-- 15-minute buckets aligned to epoch
SELECT lakets.time_bucket('15 minutes', time) AS bucket,
       count(*) AS events
FROM events
GROUP BY 1;

-- Monthly aggregation
SELECT lakets.time_bucket('1 month', time) AS month,
       sum(revenue) AS monthly_revenue
FROM transactions
GROUP BY 1 ORDER BY 1;
```

## `first(value, timestamp)` — custom aggregate

Returns the value associated with the **earliest** timestamp in the group.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | DOUBLE PRECISION | The value to return |
| `timestamp` | TIMESTAMPTZ | The ordering timestamp |

**Returns**: `DOUBLE PRECISION`

- **Internal state type**: `_first_last_state` composite `(value DOUBLE PRECISION, ts TIMESTAMPTZ)`
- **Helper functions**: `_first_sfunc` (state transition), `_first_ffunc` (final extraction)

```sql
-- Open / high / low / close per hour for a price feed
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       lakets.first(price, time) AS open_price,
       lakets.last(price, time)  AS close_price,
       max(price) AS high,
       min(price) AS low
FROM trades
GROUP BY 1;
```

## `last(value, timestamp)` — custom aggregate

Returns the value associated with the **latest** timestamp in the group.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | DOUBLE PRECISION | The value to return |
| `timestamp` | TIMESTAMPTZ | The ordering timestamp |

**Returns**: `DOUBLE PRECISION`

Internal state type: `_first_last_state` (shared with `first`).

## `time_bucket_gapfill(p_interval, p_start, p_finish)`

Generates a continuous series of time buckets between start and finish. Use with `LEFT JOIN` to produce gap-filled results.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_interval` | INTERVAL | — | Bucket width |
| `p_start` | TIMESTAMPTZ | — | Series start (inclusive) |
| `p_finish` | TIMESTAMPTZ | — | Series end (inclusive — the bucket aligned to `p_finish` is included) |

**Returns**: `SETOF TIMESTAMPTZ`

```sql
SELECT g.bucket, d.avg_temp
FROM lakets.time_bucket_gapfill('1 hour', '2026-04-01', '2026-04-02') AS g(bucket)
LEFT JOIN (
    SELECT lakets.time_bucket('1 hour', time) AS bucket,
           avg(temperature) AS avg_temp
    FROM sensor_data
    WHERE time >= '2026-04-01' AND time < '2026-04-02'
    GROUP BY 1
) d ON d.bucket = g.bucket
ORDER BY g.bucket;
```

## `locf(p_value, p_prev_value)`

**Last Observation Carried Forward.** Fills NULL values with the most recent non-NULL value. Use with window functions over gap-filled series.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value (may be NULL) |
| `p_prev_value` | DOUBLE PRECISION | `NULL` | Previous non-NULL value from window |

**Returns**: `DOUBLE PRECISION` — `p_value` if not NULL, else `p_prev_value`

```sql
SELECT bucket,
       lakets.locf(
           avg_temp,
           lag(avg_temp) OVER (ORDER BY bucket)
       ) AS filled_temp
FROM gapfilled_data;
```

## `interpolate(p_value, p_prev_value, p_next_value, p_prev_time, p_curr_time, p_next_time)`

Linear interpolation between two known data points. Computes value at `p_curr_time` proportional to its position between `p_prev_time` and `p_next_time`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_value` | DOUBLE PRECISION | Current value (returned as-is if not NULL) |
| `p_prev_value` | DOUBLE PRECISION | Previous known value |
| `p_next_value` | DOUBLE PRECISION | Next known value |
| `p_prev_time` | TIMESTAMPTZ | Time of previous value |
| `p_curr_time` | TIMESTAMPTZ | Time to interpolate at |
| `p_next_time` | TIMESTAMPTZ | Time of next value |

**Returns**: `DOUBLE PRECISION`

**Formula**: `prev_value + (next_value - prev_value) * (curr_time - prev_time) / (next_time - prev_time)`

```sql
SELECT bucket,
       lakets.interpolate(
           avg_temp,
           lag(avg_temp)  OVER w,
           lead(avg_temp) OVER w,
           lag(bucket)    OVER w,
           bucket,
           lead(bucket)   OVER w
       ) AS interpolated_temp
FROM gapfilled_data
WINDOW w AS (ORDER BY bucket);
```

## `delta(p_value, p_prev_value, p_handle_resets)`

Difference between consecutive values. Handles counter resets (where value drops below previous — e.g. restarted process counters).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value |
| `p_prev_value` | DOUBLE PRECISION | — | Previous value |
| `p_handle_resets` | BOOLEAN | `TRUE` | Treat negative delta as counter reset (returns current value) |

**Returns**: `DOUBLE PRECISION`

```sql
SELECT time,
       lakets.delta(
           bytes_sent,
           lag(bytes_sent) OVER (ORDER BY time)
       ) AS bytes_delta
FROM network_stats;
```

## `rate(p_value, p_prev_value, p_time, p_prev_time, p_handle_resets)`

Rate of change per second between consecutive points. Essential for monitoring counters.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_value` | DOUBLE PRECISION | — | Current value |
| `p_prev_value` | DOUBLE PRECISION | — | Previous value |
| `p_time` | TIMESTAMPTZ | — | Current timestamp |
| `p_prev_time` | TIMESTAMPTZ | — | Previous timestamp |
| `p_handle_resets` | BOOLEAN | `TRUE` | Handle counter resets |

**Returns**: `DOUBLE PRECISION` — change per second

```sql
-- Requests per second from a monotonic counter
SELECT lakets.time_bucket('1 minute', time) AS bucket,
       avg(lakets.rate(
           request_count,
           lag(request_count) OVER (PARTITION BY host ORDER BY time),
           time,
           lag(time) OVER (PARTITION BY host ORDER BY time)
       )) AS rps
FROM http_metrics
GROUP BY 1;
```

## `histogram(p_value, p_min, p_max, p_num_buckets)`

Returns a **bucket index** for frequency-distribution analysis.

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_value` | DOUBLE PRECISION | Value to classify |
| `p_min` | DOUBLE PRECISION | Histogram lower bound |
| `p_max` | DOUBLE PRECISION | Histogram upper bound |
| `p_num_buckets` | INT | Number of equal-width buckets |

**Returns**: `INT` — bucket index (0-based). `NULL` for NULL input. Out-of-range values are clamped: below `p_min` returns `0`, at or above `p_max` returns `p_num_buckets - 1`.

```sql
-- Distribution of response times in 10 buckets between 0 and 1000ms
SELECT lakets.histogram(response_ms, 0, 1000, 10) AS bucket,
       count(*) AS frequency
FROM requests
WHERE time >= now() - interval '1 hour'
GROUP BY 1 ORDER BY 1;
```
