---
title: Alert rules
sidebar_label: Alerts
sidebar_position: 7
description: SQL-native threshold and deadman alerts that run inside Lakebase against hot data.
---

# Alert rules

LakeTS supports two alert primitives inside Lakebase — no external alerting service required. Both run as plain SQL functions, so you can schedule them with `pg_cron`, the Databricks bundle, or any other scheduler.

## Threshold alerts

Fire when a query returns rows. Use this for "CPU > 90", "queue depth > N", etc.

```sql
SELECT * FROM lakets.alert_check(
    'high_cpu',
    $$SELECT host, max(cpu) as peak
      FROM system_metrics
      WHERE time > now() - interval '5 minutes'
      GROUP BY host HAVING max(cpu) > 90$$,
    'critical'
);
```

Returns each violating row tagged with severity, alert name, and timestamp.

## Deadman alerts

Fire when expected data **stops** arriving. Use this for sensor liveness, ingest pipeline health, etc.

```sql
SELECT * FROM lakets.alert_deadman(
    'stale_hosts', 'system_metrics', 'host', '5 minutes'
);
```

Returns hosts that haven't reported in the last 5 minutes.

## Wiring to external systems

Alert functions return rows. Wrap them in your scheduler of choice and pipe the output to:

- PagerDuty / Opsgenie via webhook
- A Slack channel via the Databricks SQL Alert framework
- A separate `_alerts_fired` ChronoTable for historical analysis

See the [Alerts reference](../reference/alerts.md) for additional helpers.
