---
title: Last Value Cache
sidebar_label: Last Value Cache
sidebar_position: 7
description: Trigger-maintained current-state cache for sub-10 ms "what's the latest reading" queries.
---

# Last Value Cache

Sub-10 ms access to the latest state of each time series. Uses a trigger-maintained cache table with `PRIMARY KEY` on the key columns — writes upsert into the cache automatically.

## `enable_lvc(p_table_name, p_key_columns, p_value_columns, p_schema_name)`

Creates the cache table `_lvc_{table}` and installs an `AFTER INSERT` trigger that upserts the latest row on every insert to the source ChronoTable.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Source ChronoTable |
| `p_key_columns` | TEXT[] | — | Columns that identify a unique series |
| `p_value_columns` | TEXT[] | — | Columns to cache the latest values of |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
-- Cache latest sensor readings by device
SELECT lakets.enable_lvc(
    'sensor_data',
    ARRAY['device_id'],
    ARRAY['temperature', 'humidity']
);

-- Insert new data — LVC cache updates automatically
INSERT INTO sensor_data VALUES (now(), 'device-42', 23.5, 65.2);
```

## `latest_values(p_table_name, p_schema_name)`

Reads from the LVC cache table. Sub-10 ms response regardless of the source table size.

**Returns**: `SETOF RECORD`

```sql
SELECT * FROM lakets.latest_values('sensor_data')
    AS t(device_id TEXT, temperature DOUBLE PRECISION, humidity DOUBLE PRECISION);
```

## `disable_lvc(p_table_name, p_schema_name)`

Removes the cache table and trigger.

## `lvc_stats()`

Overview of all LVC-enabled tables with cache statistics.

**Returns**: TABLE — `chronotable`, `cache_table`, `cached_series`, `key_columns`, `value_columns`, `enabled`
