# Lakehouse Sync Setup for LakeTS

Lakehouse Sync streams data from Lakebase to Delta Lake via CDC (Change Data Capture) using the `wal2delta` extension. This enables:
- Cold storage tiering to Delta Lake
- Cross-tier queries via Lakehouse Federation
- Analytics on historical data using Photon/Spark

## How It Works

```
ChronoTable (partitioned) --trigger--> Shadow Table (unpartitioned)
                                           |
                                      wal2delta CDC
                                           |
                                      Delta Table (append log)
                                           |
                                      Current-State View (deduplicated)
```

Lakehouse Sync does not support partitioned tables directly. LakeTS uses a **shadow table pattern**: an unpartitioned table with `REPLICA IDENTITY FULL` receives forwarded writes via a trigger, and wal2delta syncs the shadow table to Delta.

## Step 1: Enable Sync on a ChronoTable

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

## Step 2: Configure Lakehouse Sync in Databricks

1. Open your Lakebase instance in the Databricks UI
2. Navigate to **Branch overview** > **Lakehouse sync** tab
3. Click **Start sync**
4. Select the schema containing your shadow tables (e.g., `public`)
5. Configure the destination Unity Catalog catalog and schema
6. Start the sync

The shadow table `_shadow_metrics` will appear as `lb__shadow_metrics_history` in your Unity Catalog.

## Step 3: Monitor Sync Status

From Lakebase:
```sql
SELECT * FROM wal2delta.tables;
-- status: STREAMING or SNAPSHOTTING
-- committed_lsn: latest synced position
-- last_write_time: when last write occurred
```

## Step 4: Query Data from Delta

The Delta table is an append-only CDC log. Each row has:
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

## Step 5: Cross-Tier Queries (Federation)

Query both hot (Lakebase) and cold (Delta) data in a single query:
```sql
-- Hot data from Lakebase
SELECT time, device, cpu FROM metrics WHERE time > now() - interval '7 days'
UNION ALL
-- Cold data from Delta (via Lakehouse Federation)
SELECT time, device, cpu FROM catalog.schema.metrics_archive WHERE time <= now() - interval '7 days'
ORDER BY time DESC;
```

## Disabling Sync

```sql
SELECT lakets.disable_sync('metrics');
```

This drops the shadow table, removes the trigger, and updates the registry. It does **not** delete data already synced to Delta.

## Limitations

| Limitation | Workaround |
|-----------|------------|
| Partitioned tables can't be synced | Shadow table pattern (handled by LakeTS) |
| Schema changes break sync | Create new shadow table, re-enable sync, backfill |
| Unidirectional (Lakebase -> Delta only) | Re-ingest from Delta via Databricks Job for re-heating |
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
