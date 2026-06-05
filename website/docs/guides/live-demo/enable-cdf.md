---
title: Enable CDF
sidebar_label: Enable CDF
sidebar_position: 4
---

## Step 4 — Enable Lakebase CDF on `lakets_cdf`

Step 3.6 (`enable_sync`) created the unpartitioned shadow in the `lakets_cdf` schema —
with `REPLICA IDENTITY FULL` set automatically — and its mirror trigger. LakeTS cannot
turn on this managed sync itself, so enable it once in the Databricks UI:

1. Open the Lakebase project, then **Branch overview → CDF**.
2. Click **Start sync** and select the **`lakets_cdf`** schema.
3. Set the destination Unity Catalog catalog and schema.
4. Start the sync.

CDF snapshots the shadow, then switches to continuous streaming. Without this step the
shadow fills but never reaches Unity Catalog, so **no chunk is ever flagged or dropped** —
the durability gate is never satisfied. Confirm it is streaming:

```sql
SELECT table_oid::regclass AS shadow, status, committed_lsn
FROM wal2delta.tables;   -- status: SNAPSHOTTING, then STREAMING
```

See [Lakebase CDF setup](../lakebase-cdf-setup.md) for the full walkthrough.

---
