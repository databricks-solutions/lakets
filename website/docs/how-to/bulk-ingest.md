---
title: Bulk ingest
sidebar_label: Bulk ingest
sidebar_position: 6
description: Insert batches from edge devices, protocol adapters, or other writers using the JSONB ingest function.
---

# Bulk ingest

Streaming writers, edge devices, and protocol adapters typically deliver data in batches. `lakets.ingest_batch` accepts a JSONB array and writes it into a multi-metric ChronoTable in a single call, which costs far less than per-row inserts.

## Insert a batch

```sql
SELECT lakets.ingest_batch('system_metrics', '[
    {"time": "2026-03-25T17:00:00Z", "host": "edge-01", "region": "eu-1", "env": "prod", "cpu": 55.5, "memory": 2048, "disk_io": 100},
    {"time": "2026-03-25T17:00:01Z", "host": "edge-02", "region": "eu-1", "env": "prod", "cpu": 66.6, "memory": 4096, "disk_io": 200}
]'::JSONB);
```

The function:

- Validates required tag and field columns against the ChronoTable's registry
- Routes each row to the correct time-partitioned chunk via standard Postgres `PARTITION BY RANGE`
- Returns the number of rows inserted

## Automatic rollup invalidation

Bulk inserts fire the statement-level invalidation trigger, so any RollUp that depends on the ChronoTable has its affected buckets marked dirty automatically. There is no need to call `invalidate_rollup_range`.

## Prometheus-format ingest

LakeTS also ships an adapter that accepts Prometheus exposition format and writes to a configured multi-metric table. See the [Bulk ingest reference](../reference/bulk-ingest.md).
