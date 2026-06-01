---
title: Time series functions
sidebar_label: Time series functions
sidebar_position: 2
description: How time_bucket, first, last, locf, interpolate, gapfill, delta, and rate work internally.
---

# How Time Series Functions Work

LakeTS provides specialized SQL functions for common time series patterns. Here's how each one works internally.

## time_bucket — "Round timestamps to intervals"

**What it does**: Groups timestamps into fixed-width buckets. Like `date_trunc` but for any interval.

```sql
SELECT lakets.time_bucket('1 hour'::interval, '2026-03-25 14:37:22'::timestamptz);
-- Returns: 2026-03-25 14:00:00
```

**How it works internally**:
- For intervals shorter than a month (hours, minutes, days): delegates to Postgres's built-in `date_bin()` function — very fast
- For month/year intervals: custom math that counts months since an origin and rounds down

```
Input:  2026-03-25 14:37:22
        |
        v
Is interval in months? --NO--> date_bin('1 hour', timestamp, origin)
                       |                    |
                       YES                  v
                       |            2026-03-25 14:00:00
                       v
              Month math: (year*12 + month) / interval_months * interval_months
                       |
                       v
              2026-03-01 00:00:00 (for '1 month' interval)
```

## first / last — "Value at the earliest/latest time"

**What they do**: Return the value associated with the minimum or maximum timestamp in a group.

```sql
SELECT device, lakets.first(cpu, time) as first_reading
FROM metrics GROUP BY device;
```

**How they work**: These are **custom Postgres aggregates** — they maintain internal state as they process each row:

```
Processing rows for device_0:
  Row 1: (cpu=50, time=10:00) -> state = {value: 50, ts: 10:00}  (first row)
  Row 2: (cpu=60, time=11:00) -> state = {value: 50, ts: 10:00}  (11:00 > 10:00, keep existing)
  Row 3: (cpu=40, time=09:00) -> state = {value: 40, ts: 09:00}  (09:00 < 10:00, update!)
  Final: return state.value = 40
```

The aggregate is defined with `CREATE AGGREGATE`, which tells Postgres to call the state-transition function (`_first_sfunc`) for each row, then the final function (`_first_ffunc`) to extract the result.

## time_bucket_gapfill — "Fill in missing time buckets"

**The problem**: Real data has gaps. If `sensor_0` didn't report at 3 PM, your hourly aggregation skips that hour entirely.

**The solution**: Generate all expected buckets, then `LEFT JOIN` with your data.

```
Expected buckets:     Actual data:          After LEFT JOIN:
  10:00                 10:00 -> 42           10:00 -> 42
  11:00                 11:00 -> 55           11:00 -> 55
  12:00                                       12:00 -> NULL (gap!)
  13:00                 13:00 -> 38           13:00 -> 38
  14:00                                       14:00 -> NULL (gap!)
```

**How it works**: `time_bucket_gapfill` is a wrapper around `generate_series`:

```sql
-- This:
SELECT * FROM lakets.time_bucket_gapfill('1 hour', start, finish);

-- Is equivalent to:
SELECT generate_series(
    lakets.time_bucket('1 hour', start),
    lakets.time_bucket('1 hour', finish),
    '1 hour'::interval
);
```

## locf — "Carry forward the last known value"

**What it does**: Fills NULLs with the previous non-NULL value. Like saying "if no new reading, assume the last one is still valid."

```
Before LOCF:  42, 55, NULL, 38, NULL
After LOCF:   42, 55, 55,   38, 38
```

**How it works**: It's a simple `COALESCE(current_value, previous_value)`. You provide the previous value using `LAG()`:

```sql
lakets.locf(value, LAG(value) OVER (ORDER BY time))
-- If value is NULL, returns the LAG value
-- If value is not NULL, returns value itself
```

## interpolate — "Draw a straight line between known points"

```
Known: (10:00, 100) and (12:00, 200)
What's the value at 11:00?

Answer: 150 (halfway between 100 and 200)
```

**How it works**: Linear interpolation formula:

```
result = prev_value + (next_value - prev_value) * (elapsed / total_duration)
       = 100       + (200        - 100       ) * (1 hour  / 2 hours       )
       = 100       + 50
       = 150
```

## delta & rate — "How much did it change?"

- **delta**: `current_value - previous_value` (handles counter resets)
- **rate**: `delta / seconds_elapsed` (change per second)

```
Time    CPU Counter    Delta    Rate (per sec)
10:00   1000           —        —
10:01   1060           60       1.0/sec
10:02   1130           70       1.17/sec
10:03   50             50       0.83/sec  <-- counter reset! (50 < 1130, so delta = 50, not -1080)
```
