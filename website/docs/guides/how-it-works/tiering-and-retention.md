---
title: Tiering & retention
sidebar_label: Tiering & retention
sidebar_position: 4
description: How LakeTS validates that cold chunks are durable in Unity Catalog, then reclaims Lakebase storage by dropping them at drop_after.
---

import useBaseUrl from '@docusaurus/useBaseUrl';

export const Demo = ({src, poster}) => (
  <video autoPlay loop muted playsInline poster={useBaseUrl(poster)}
    style={{ width: '100%', borderRadius: '0.75rem', margin: '1.25rem 0', border: '1px solid rgba(127,127,127,0.18)' }}>
    <source src={useBaseUrl(src)} type="video/mp4" />
  </video>
);

# How tiering and retention work

Your data has two copies: the **hot** copy in Lakebase (fast, billed for storage) and the **cold** copy in the Unity Catalog Managed Table that Lakebase CDF maintains continuously. Tiering and retention decide **how long the Lakebase copy is kept** — they never touch the Unity Catalog copy.

A chunk moves through three states:

| State | Where it is | Meaning |
|---|---|---|
| `active` | Lakebase | Recent; not yet validated as durable in UC |
| `tiered` | **Lakebase** + Unity Catalog | Past `tier_after` and CDF-confirmed durable in UC — flagged ready to drop, but still resident and queryable |
| `dropped` | Unity Catalog only | Past `drop_after`; the Lakebase partition has been removed |

<Demo src="/video/tiered-retention.mp4" poster="/video/tiered-retention-poster.png" />

The important point: **`tier_after` does not remove anything.** It validates and flags. Only `drop_after` frees Lakebase storage, and the Unity Catalog copy is retained regardless.

## Tiering — validate and flag

A tiering policy marks chunks older than `p_after` for validation:

```sql
SELECT lakets.add_tiering_policy('metrics', '7 days');
```

The [Tiering job](../../reference/workflow-jobs.md) calls `tier_chunk` on each aged chunk. When the durability gate passes, `tier_chunk` sets the chunk's status to `tiered` — **the partition is not dropped, the data stays in Lakebase.** Adding the policy installs the per-chunk write-tracking triggers and backfills every existing chunk's `last_write_lsn` to the current WAL position (a chunk with no recorded write position can't be proven durable, so the backfill is what makes pre-existing chunks eligible).

Tiering requires Lakebase CDF: the table must be synced with `lakets.enable_sync('metrics')` and CDF must be streaming on the `lakets_cdf` schema. `add_tiering_policy` still succeeds on an un-synced table (with a notice), but no chunk is flagged until the sync streams.

## The durability gate

A chunk is only ever considered safe to remove from Lakebase when all three conditions hold:

1. The chunk's CDF **shadow table** is `STREAMING` in `wal2delta.tables`.
2. The chunk has a recorded `last_write_lsn` (not NULL).
3. CDF's `committed_lsn` for that shadow is **≥ the chunk's `last_write_lsn`**.

Together these prove CDF has flushed every write to that chunk into the Unity Catalog Managed Table. `tier_chunk` uses this gate to flag a chunk `tiered`, and retention re-checks it before physically dropping the partition.

<Demo src="/video/tiering.mp4" poster="/video/tiering-poster.png" />

The comparison is against the chunk's own recorded write position, not the global WAL head. A shadow's `committed_lsn` stops advancing while it is idle, but the WAL head keeps moving from unrelated activity — so a head comparison would never pass for exactly the cold, idle chunks tiering targets. Per-chunk write positions are stamped by statement-level triggers installed with the policy.

The gate is **fail-closed**: when it cannot be satisfied, the chunk is deferred and retried on the next run. A missing, degraded, or lagging CDF never reads as safe. `show_tiering_status` reports per-table progress — `cdf_status`, pending chunks, and whether the gate is currently caught up.

## Retention — dropping from Lakebase

Retention is the only step that removes data from Lakebase. `execute_retention` drops the partition of each chunk older than `drop_after`:

```sql
SELECT lakets.add_retention_policy('metrics', '90 days');
```

- The drop is **gated** whenever the data is expected to live on in Unity Catalog — a **CDF-synced** table, **or** a **`tiered_retention`** policy (whose intent is a cold copy). A chunk is dropped only if provably durable (`committed_lsn ≥ last_write_lsn`); otherwise it is deferred and retried. Gating `tiered_retention` by intent — not just the sync flag — means a policy created before `enable_sync` never silently deletes un-mirrored data.
- Only **plain `retention` on an un-synced table** (no cold copy) drops outright.
- Passing `p_force => TRUE` bypasses the durability check and drops regardless — use it only when you accept that an un-validated chunk's data may not yet be in UC.

In every case only the Lakebase partition is removed; the chunk is marked `dropped`.

## Tiered retention

`add_tiered_retention_policy` declares both horizons at once and validates that `tier_after < drop_after`:

```sql
SELECT lakets.add_tiered_retention_policy('metrics',
    '7 days',    -- tier_after: validate + flag (data stays in Lakebase)
    '90 days');  -- drop_after: remove the Lakebase partition (gated)
```

So a chunk is hot and queryable in Lakebase for the whole window up to `drop_after`; `tier_after` only marks the point at which it has been confirmed safe in Unity Catalog.

:::warning LakeTS does not delete from the cold tier
Every LakeTS lifecycle action removes data only from **Lakebase**. The Unity Catalog Managed Table is the durable, long-term copy and is **not** deleted by LakeTS — there is no path that removes cold-tier data from Lakebase. Pruning the lakehouse copy, if you ever need to, is a separate operation performed in Databricks.
:::

:::tip RollUps outlive their source
RollUp tables persist in Lakebase regardless of retention. You can drop raw data older than 30 days while keeping hourly and daily RollUps indefinitely.
:::

## Late arrivals and backfills

Because a chunk stays resident in Lakebase right up to `drop_after`, late or backfilled data lands in a real partition and is corrected automatically: a late `INSERT` (or bulk `COPY`) flags the affected RollUp buckets through the statement-level trigger, and an `UPDATE`/`DELETE` correction flags them through the per-row trigger, so the next refresh re-aggregates just those buckets from Lakebase. A backfilled chunk also can't be dropped prematurely — retention re-checks the durability gate at drop time, deferring until CDF has flushed the new data to Unity Catalog.

The implication for sizing: **set `drop_after` larger than your worst-case data lateness** so late rows still find a resident partition. Once a chunk is `dropped`, a late row for that window is rejected by Lakebase, and its RollUp buckets can no longer be recomputed — they keep their last computed value. See [Configure data lifecycle → Choosing `tier_after` and `drop_after`](../../how-to/lifecycle.md#choosing-tier_after-and-drop_after) for concrete duration guidance and late-arrival best practices.
