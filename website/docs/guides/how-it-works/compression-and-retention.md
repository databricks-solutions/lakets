---
title: Compression & retention
sidebar_label: Compression & retention
sidebar_position: 4
description: How LakeTS tiers cold chunks to Unity Catalog and drops expired data.
---

# How Compression & Tiering Works

## The concept

Think of your data like files on a desk:
- **Hot desk** (Lakebase): Papers you're actively reading. Fast access.
- **Filing cabinet** (Unity Catalog Managed Table): Papers from last month. Slower but organized.
- **Shredder** (Retention): Papers older than a year. Gone.

## How policies work

When you add a compression policy, LakeTS stores the rule in `_policy_registry`:

```sql
SELECT lakets.add_compression_policy('metrics', '7 days');
-- Stores: {compress_after: "7 days", segment_by: null, order_by: "time DESC"}
```

Nothing happens immediately. The policy is a **declaration of intent**. The actual work is done by the Databricks compression job that runs on a schedule:

```mermaid
flowchart LR
    subgraph JOB["Compression Job (runs daily at 2 AM)"]
        A["1. Query _policy_registry<br/>for compression policies"] --> B["2. Query _get_chunks_to_compress()<br/>find chunks older than 7 days"]
        B --> C["3. For each chunk:<br/>mark compressed in metadata"]
        C --> D["4. Optionally drop<br/>Lakebase partition"]
    end

    subgraph BEFORE["Before"]
        P1["Mar 15 chunk (active)"]
        P2["Mar 16 chunk (active)"]
        P3["Mar 17 chunk (active)"]
    end

    subgraph AFTER["After (compress_after=7 days, today=Mar 25)"]
        P4["Mar 15 chunk (compressed)"]
        P5["Mar 16 chunk (compressed)"]
        P6["Mar 17 chunk (compressed)"]
        P7["Mar 18 chunk (active - only 7 days old)"]
    end
```

The data in the Unity Catalog Managed Table is already there (via Lakebase CDF). The compression job's main purpose is to **free Lakebase storage** by dropping old partitions once we know the data is safely in the cold tier.

---

# How Retention Works

Retention is simpler than compression — it just drops old chunks:

```sql
SELECT lakets.add_retention_policy('metrics', '30 days');
```

When `execute_retention` runs:

1. Looks up the policy in `_policy_registry`
2. Calls `drop_chunks('metrics', '30 days')` which:
   - Finds chunks where `range_end <= now() - 30 days`
   - Runs `DROP TABLE` on each partition (instant, no row-by-row delete)
   - Updates `_chunk_metadata` status to `dropped`

**Tiered retention** adds a two-step lifecycle:

```
Day 0-7:    HOT (Lakebase, fast queries)
Day 7-90:   WARM (Unity Catalog Managed Table, tiered via compression policy)
Day 90+:    DELETED (retention policy drops from both tiers)
```

:::tip RollUps survive retention
You can drop all raw data older than 30 days while keeping your hourly/daily RollUp tables forever.
:::
