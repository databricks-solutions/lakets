---
title: Time series functions
sidebar_label: Time series functions
sidebar_position: 2
description: How time_bucket, first, last, gapfill, locf, interpolate, delta, rate, and histogram transform a time series.
---

import useBaseUrl from '@docusaurus/useBaseUrl';

export const Demo = ({src, poster}) => (
  <video autoPlay loop muted playsInline poster={useBaseUrl(poster)}
    style={{ width: '100%', borderRadius: '0.75rem', margin: '1.25rem 0', border: '1px solid rgba(127,127,127,0.18)' }}>
    <source src={useBaseUrl(src)} type="video/mp4" />
  </video>
);

# How Time Series Functions Work

LakeTS adds the analytical functions time series work depends on — bucketing, gap handling, rates, and distributions — as plain `IMMUTABLE` SQL. Each one is a small transformation on your data; the animations below show what each does to a series, and the snippet shows how you call it. For full signatures and parameters, see the [reference](../../reference/time-series-functions.md).

## `time_bucket` — align timestamps to fixed buckets

Rounds each timestamp **down** to its bucket boundary, so irregular events become aligned buckets you can `GROUP BY`. Sub-month intervals delegate to Postgres's `date_bin()`; month/year intervals use calendar-aware arithmetic.

<Demo src="/video/ts-time-bucket.mp4" poster="/video/ts-time-bucket-poster.png" />

```sql
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       avg(temperature) AS avg_temp
FROM sensor_data
GROUP BY 1 ORDER BY 1;
```

## `first` / `last` — earliest & latest value per bucket

Custom aggregates that return the value at the **minimum** (`first`) or **maximum** (`last`) timestamp in each group — the open and close of every window.

<Demo src="/video/ts-first-last.mp4" poster="/video/ts-first-last-poster.png" />

```sql
-- Open / high / low / close per hour
SELECT lakets.time_bucket('1 hour', time) AS bucket,
       lakets.first(price, time) AS open,
       lakets.last(price, time)  AS close,
       max(price) AS high,
       min(price) AS low
FROM trades
GROUP BY 1;
```

## `time_bucket_gapfill` — surface the missing buckets

Real data has gaps: if a sensor doesn't report for an hour, that bucket simply disappears from a `GROUP BY`. `time_bucket_gapfill` emits **every** bucket in the range, so a `LEFT JOIN` turns missing buckets into explicit `NULL` rows instead of vanishing.

<Demo src="/video/ts-gapfill.mp4" poster="/video/ts-gapfill-poster.png" />

```sql
SELECT g.bucket, d.avg_temp
FROM lakets.time_bucket_gapfill('1 hour', '2026-04-01', '2026-04-02') AS g(bucket)
LEFT JOIN (
    SELECT lakets.time_bucket('1 hour', time) AS bucket, avg(temperature) AS avg_temp
    FROM sensor_data
    WHERE time >= '2026-04-01' AND time < '2026-04-02'
    GROUP BY 1
) d ON d.bucket = g.bucket
ORDER BY g.bucket;
```

## `locf` — carry the last value forward

**Last Observation Carried Forward.** Fills each `NULL` with the most recent non-NULL value — a flat hold until the next real reading. You supply the previous value with a window `lag()`.

<Demo src="/video/ts-locf.mp4" poster="/video/ts-locf-poster.png" />

```sql
SELECT bucket,
       lakets.locf(avg_temp, lag(avg_temp) OVER (ORDER BY bucket)) AS filled_temp
FROM gapfilled_data;
```

## `interpolate` — draw a straight line between known points

Where `locf` holds flat, `interpolate` fills a gap **linearly** — it reads the value on the straight line between the two surrounding points (e.g. 150 halfway between 100 and 200).

<Demo src="/video/ts-interpolate.mp4" poster="/video/ts-interpolate-poster.png" />

```sql
SELECT bucket,
       lakets.interpolate(
           avg_temp,
           lag(avg_temp)  OVER w, lead(avg_temp) OVER w,
           lag(bucket)    OVER w, bucket, lead(bucket) OVER w
       ) AS interpolated_temp
FROM gapfilled_data
WINDOW w AS (ORDER BY bucket);
```

## `delta` / `rate` — how much did it change?

`delta` is the change between consecutive values; `rate` divides that by the elapsed seconds. Both handle **counter resets**: when a value drops below the previous one (a restarted counter), the change is taken as the new value rather than a large negative spike.

<Demo src="/video/ts-delta-rate.mp4" poster="/video/ts-delta-rate-poster.png" />

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

## `histogram` — map each value to a bin

Returns a 0-based **bucket index** for a value across `p_num_buckets` equal-width bins between `p_min` and `p_max` (out-of-range values are clamped). Count the rows per bin and you get a frequency distribution.

<Demo src="/video/ts-histogram.mp4" poster="/video/ts-histogram-poster.png" />

```sql
-- Distribution of response times in 10 buckets between 0 and 1000ms
SELECT lakets.histogram(response_ms, 0, 1000, 10) AS bucket,
       count(*) AS frequency
FROM requests
WHERE time >= now() - interval '1 hour'
GROUP BY 1 ORDER BY 1;
```
