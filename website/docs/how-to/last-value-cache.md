---
title: Last Value Cache
sidebar_label: Last Value Cache
sidebar_position: 5
description: Trigger-maintained current-state cache for sub-10ms latest-reading queries.
---

# Last Value Cache (LVC)

The Last Value Cache maintains the most recent row per key in a small table, updated by a trigger on every write. Status widgets, current-value tiles, and real-time alerts read from that table instead of scanning a ChronoTable for `MAX(time)` on each refresh, which keeps lookups in the sub-10ms range.

## Enable LVC

```sql
SELECT lakets.enable_lvc(
    'system_metrics',
    key_columns   := ARRAY['host'],
    value_columns := ARRAY['cpu', 'memory']
);
```

This creates `_lvc_system_metrics` and an `AFTER INSERT` trigger that upserts into the cache table on every write to `system_metrics`.

## Query the cache

```sql
INSERT INTO system_metrics
VALUES (now(), 'web-01', 'us-west-2', 'prod', 85.0, 7000, 500);

-- The cache reflects this immediately
SELECT * FROM _lvc_system_metrics;
-- host   | cpu  | memory | last_updated
-- web-01 | 85.0 | 7000   | 2026-03-25 17:30:01
```

## Cache statistics

```sql
SELECT * FROM lakets.lvc_stats();
```

Returns hit count, miss count, last_updated_at per LVC-enabled ChronoTable.

## When to use

| Use case | LVC vs raw query |
|---|---|
| Status widget showing "current CPU per host" | LVC — millisecond reads |
| Real-time alert checking last value | LVC |
| Historical aggregations (averages, percentiles) | Raw ChronoTable or RollUp |
| Time-window queries (last 1h, last 30d) | Raw ChronoTable or RollUp |
