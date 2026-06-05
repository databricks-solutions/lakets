---
title: Manage tag cardinality
sidebar_label: Cardinality
sidebar_position: 8
description: Track distinct tag values to prevent label explosion in multi-metric ChronoTables.
---

# Manage tag cardinality

In a multi-metric ChronoTable, tag columns identify a series (`host`, `region`, `env`, and so on). When a tag column accidentally captures high-cardinality data such as a request ID, the table expands into millions of distinct series and query performance degrades. LakeTS provides two functions to detect this condition early.

## Inspect cardinality per tag

```sql
SELECT * FROM lakets.cardinality_stats('system_metrics');
-- column | distinct_values | total_rows | pct_of_rows
-- host   | 150             | 100000     | 0.150%
-- region | 5               | 100000     | 0.005%
-- env    | 3               | 100000     | 0.003%
```

`pct_of_rows` is the key indicator. Healthy tags sit well under 1%. A column approaching 10% or more is behaving like a primary key and is almost certainly a mis-modelled field.

## Set a cardinality budget

```sql
SELECT * FROM lakets.cardinality_check('system_metrics', 10000);
-- status | combined_cardinality | max_allowed
-- OK     | 750                  | 10000
```

`combined_cardinality` is the product of distinct values across all tag columns, which is the actual series count. Run this in a scheduled job and alert on `status != 'OK'`.

## Common fixes

| Smell | Fix |
|---|---|
| `request_id` as a tag | Move to a field column or drop entirely |
| User-controlled string in a tag | Hash or bucket it before insert |
| Composite key with timestamp embedded | Split out the time component into the `time` column |
