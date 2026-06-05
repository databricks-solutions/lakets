---
title: Lakebase CDF Setup
sidebar_label: Lakebase CDF Setup
sidebar_position: 3
description: Stream data from Lakebase to a Unity Catalog Managed Table via CDC.
---

# Lakebase CDF Setup for LakeTS

Lakebase CDF streams data from Lakebase to a Unity Catalog Managed Table via CDC (Change Data Capture). It gives you:

- Cold-storage tiering to a Unity Catalog Managed Table
- Query the cold tier directly in Databricks (Spark / Databricks SQL)
- Analytics on historical data using Spark

## Prerequisites

- A Databricks workspace with Lakebase enabled
- A Lakebase **autoscale** instance running **PostgreSQL 16 or later**
- LakeTS installed on that instance ([Quickstart](./getting-started.md))
- At least one ChronoTable to sync

## How It Works

```
ChronoTable (partitioned) --trigger--> Shadow Table (unpartitioned)
                                           |
                                       Lakebase CDF
                                           |
                                  UC Managed Table (append log)
                                           |
                                  Current-State View (deduplicated)
```

Lakebase CDF does not support partitioned tables directly. LakeTS uses a **shadow table pattern**: an unpartitioned table with `REPLICA IDENTITY FULL` receives forwarded writes via a trigger, and Lakebase CDF syncs the shadow table to the Unity Catalog Managed Table.

## Step 1: Enable CDF on a ChronoTable

```sql
-- The ChronoTable must already exist
SELECT lakets.enable_sync('metrics');
```

This creates:
- `_shadow_metrics` — unpartitioned table with same schema
- A trigger that forwards all INSERT/UPDATE/DELETE to the shadow table
- Sets `REPLICA IDENTITY FULL` on the shadow table

Verify:
```sql
SELECT sync_enabled, shadow_table_name
FROM lakets._chronotable_registry WHERE table_name = 'metrics';
-- sync_enabled=true, shadow_table_name=_shadow_metrics
```

## Step 2: Configure Lakebase CDF in Databricks

1. Open your Lakebase instance in the Databricks UI
2. Navigate to **Branch overview** > **CDF** tab
3. Click **Start sync**
4. Select the schema containing your shadow tables (e.g., `public`)
5. Configure the destination Unity Catalog catalog and schema
6. Start the sync

The shadow table `_shadow_metrics` will appear as `lb__shadow_metrics_history` in your Unity Catalog.

## Step 3: Monitor Sync Status

From Lakebase:
```sql
SELECT table_oid::regclass AS shadow, status, committed_lsn
FROM wal2delta.tables;
-- status: STREAMING or SNAPSHOTTING
-- committed_lsn: latest synced position
```

## Step 4: Query Data from the Unity Catalog Managed Table

The UC Managed Table is an append-only CDC log. Each row has:
- `_change_type`: insert, delete, update_preimage, update_postimage
- `_timestamp`: when the change was captured
- `_lsn`: Log Sequence Number
- `_xid`: Transaction ID

To get the current state:
```sql
SELECT * FROM (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY device ORDER BY _lsn DESC) AS rn
    FROM catalog.schema.lb__shadow_metrics_history
    WHERE _change_type IN ('insert', 'update_postimage', 'delete')
) WHERE rn = 1 AND _change_type != 'delete';
```

## Step 5: Querying across tiers

The two tiers are queried independently, each in its own engine — LakeTS does not federate the Unity Catalog table back into Postgres.

Recent (hot) data lives in Lakebase and is queried over Postgres:
```sql
-- Hot data from Lakebase (Postgres)
SELECT time, device, cpu FROM metrics WHERE time > now() - interval '7 days'
ORDER BY time DESC;
```

Historical (cold) data lives in the Unity Catalog Managed Table and is queried in Databricks (Spark / Databricks SQL):
```sql
-- Cold data from the UC Managed Table, queried in Databricks
SELECT time, device, cpu FROM catalog.schema.metrics_archive WHERE time <= now() - interval '7 days'
ORDER BY time DESC;
```

## Disabling CDF

```sql
SELECT lakets.disable_sync('metrics');
```

This drops the shadow table, removes the trigger, and updates the registry. It does **not** delete data already synced to the UC Managed Table.

## Limitations

| Limitation | Workaround |
|-----------|------------|
| Partitioned tables can't be synced | Shadow table pattern (handled by LakeTS) |
| Schema changes break sync | Create new shadow table, re-enable CDF, backfill |
| Unidirectional (Lakebase → UC only) | Re-ingest from the UC Managed Table via Databricks Job for re-heating |
| PostGIS, pgvector, composite types not supported | Exclude from shadow table or cast to TEXT |
| Empty tables not synced | First INSERT triggers sync start |

## Supported Data Types

| Supported | Not Supported |
|-----------|---------------|
| BOOLEAN, INT, BIGINT, FLOAT, DOUBLE | PostGIS geometry/geography |
| TEXT, VARCHAR, CHAR | pgvector embeddings |
| DATE, TIMESTAMP, TIMESTAMPTZ | Composite types |
| JSONB (as STRING), ENUM (as STRING) | hstore |
| NUMERIC/DECIMAL | |
