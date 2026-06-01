---
title: Alerts
sidebar_label: Alerts
sidebar_position: 9
description: SQL-native threshold and deadman alert primitives.
---

# Alerts

SQL-native alert rules that evaluate queries and fire when conditions are met. The functions return rows; wrap them in your scheduler of choice (pg_cron, Databricks Jobs, etc.) to drive notifications.

## `alert_check(p_name, p_query, p_severity)`

Runs a query and returns any "firing" rows as alert events.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Alert rule name |
| `p_query` | TEXT | — | Query that returns rows when the alert should fire |
| `p_severity` | TEXT | `'warning'` | Severity: `'info'`, `'warning'`, `'critical'` |

**Returns**: TABLE — `alert_name`, `severity`, `fired_at`, `alert_data` (JSONB)

```sql
-- Fire when any device has avg temperature > 80°C in the last hour
SELECT * FROM lakets.alert_check(
    'high_temperature',
    $$SELECT device_id, avg(temperature) AS avg_temp
       FROM sensor_data
       WHERE time >= now() - interval '1 hour'
       GROUP BY device_id
       HAVING avg(temperature) > 80$$,
    'critical'
);
```

## `alert_deadman(p_name, p_table_name, p_group_by, p_timeout, p_schema_name)`

Detects **silent series** — groups that haven't reported data within the timeout. Essential for monitoring data-pipeline health.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_name` | TEXT | — | Alert name |
| `p_table_name` | TEXT | — | ChronoTable to check |
| `p_group_by` | TEXT | — | Column to group by (e.g. `'device_id'`) |
| `p_timeout` | INTERVAL | — | Maximum silence before alerting |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: TABLE — `alert_name`, `severity`, `fired_at`, `dead_key`, `last_seen`, `silent_for`

```sql
-- Alert if any device hasn't reported in 15 minutes
SELECT * FROM lakets.alert_deadman(
    'device_heartbeat', 'sensor_data', 'device_id', '15 minutes'
);
-- device_heartbeat | warning | 2026-04-09 10:30 | device-17 | 2026-04-09 10:12 | 00:18:00
```
