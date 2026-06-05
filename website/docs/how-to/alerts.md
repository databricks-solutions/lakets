---
title: Alert rules
sidebar_label: Alerts
sidebar_position: 7
description: SQL-native threshold and deadman alerts that run inside Lakebase against hot data.
---

# Alert rules

LakeTS provides two alert primitives that run inside Lakebase, with no external alerting service required. Both are plain SQL functions and can be scheduled with `pg_cron`, the Databricks bundle, or any other scheduler.

## Threshold alerts

A threshold alert fires when its query returns rows. It suits conditions such as CPU above 90 or queue depth above a limit.

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

The function returns each violating row tagged with severity, alert name, and timestamp.

## Deadman alerts

A deadman alert fires when expected data stops arriving. It suits sensor liveness and ingest pipeline health checks.

```sql
SELECT * FROM lakets.alert_deadman(
    'stale_hosts', 'system_metrics', 'host', '5 minutes'
);
```

The function returns hosts that have not reported in the last 5 minutes.

## Routing to external systems

Both functions return rows. Run them on a scheduler and route the output to:

- PagerDuty or Opsgenie via webhook
- A Slack channel via the Databricks SQL Alert framework
- A separate `_alerts_fired` ChronoTable for historical analysis

See the [Alerts reference](../reference/alerts.md) for additional helpers.
