---
title: Bulk ingest
sidebar_label: Bulk ingest
sidebar_position: 10
description: Server-side batch ingest functions for high-throughput writes from edge devices and Prometheus.
---

# Bulk ingest

Server-side batch ingest for high-throughput data loading from edge devices, microservices, or protocol adapters.

## `ingest_batch(p_table_name, p_data, p_schema_name)`

Inserts multiple rows from a JSONB array. Designed for edge devices or microservices that batch measurements.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Target ChronoTable |
| `p_data` | JSONB | — | Array of row objects |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `INT` — number of rows inserted

```sql
SELECT lakets.ingest_batch('sensor_data', '[
    {"time": "2026-04-09T10:00:00Z", "device_id": "d1", "temperature": 22.5, "humidity": 60},
    {"time": "2026-04-09T10:00:01Z", "device_id": "d2", "temperature": 23.1, "humidity": 58},
    {"time": "2026-04-09T10:00:02Z", "device_id": "d3", "temperature": 21.8, "humidity": 62}
]');
-- Returns: 3
```

Bulk inserts trigger LakeTS's statement-level invalidation, so RollUps that depend on this ChronoTable have the affected buckets marked dirty automatically.

## `ingest_prometheus(p_table_name, p_metric_name, p_labels, p_value, p_timestamp, p_schema_name)`

Inserts a single Prometheus-style metric. The target table must have columns: `time`, `metric_name`, `labels` (JSONB), `value`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_table_name` | TEXT | — | Target table |
| `p_metric_name` | TEXT | — | Metric name |
| `p_labels` | JSONB | — | Label key-value pairs |
| `p_value` | DOUBLE PRECISION | — | Metric value |
| `p_timestamp` | TIMESTAMPTZ | `now()` | Observation timestamp |
| `p_schema_name` | TEXT | `'public'` | Schema |

**Returns**: `VOID`

```sql
SELECT lakets.ingest_prometheus(
    'prom_metrics',
    'http_requests_total',
    '{"method": "GET", "path": "/api/v1/data", "status": "200"}'::JSONB,
    1542.0
);
```
