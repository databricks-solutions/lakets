---
title: Configure data lifecycle
sidebar_label: Data lifecycle
sidebar_position: 3
description: Add tiering, retention, and tiered retention policies so old data tiers to Unity Catalog and eventually drops.
---

# Configure data lifecycle

LakeTS gives you three policy primitives for old data: **tiering** (validate + flag chunks as durable in Unity Catalog), **retention** (drop partitions from Lakebase), and **tiered retention** (compose the two).

## Tiering — validate and flag cold data

A tiering policy marks chunks older than `p_after` for validation. The data is
already in the Unity Catalog Managed Table via Lakebase CDF; the Tiering job
confirms that and flags the chunk `tiered` (ready to drop). The chunk's data
**stays in Lakebase** and remains queryable — it is removed later by retention.

```sql
SELECT lakets.add_tiering_policy('metrics', '7 days');
```

The Databricks Tiering Job runs this. A chunk is flagged only once CDF has
confirmed its data is durable in Unity Catalog.

## Retention — drop old chunks entirely

A retention policy drops chunks older than `p_after` from Lakebase. No tiering — the data is gone (from Lakebase) once it ages out.

```sql
SELECT lakets.add_retention_policy('metrics', '30 days');
```

## Tiered retention — tier then retain

Two horizons for the **Lakebase (hot)** copy: after `p_tier_after`, validate the chunk is durable in Unity Catalog and flag it `tiered` (it stays in Lakebase); after `p_drop_after`, drop the Lakebase partition (CDF-gated).

```sql
SELECT lakets.add_tiered_retention_policy('metrics', '7 days', '90 days');
```

This is the most common production pattern:

```
Day 0-7:    HOT       — Lakebase, sub-10ms reads
Day 7-90:   VALIDATED — still in Lakebase, confirmed durable in Unity Catalog
Day 90+:    DROPPED   — Lakebase partition removed; Unity Catalog copy retained
```

Both horizons act on Lakebase only. LakeTS does not delete from the Unity Catalog tier — the cold copy is the durable long-term store, and pruning it is a separate lakehouse operation.

:::tip RollUps survive retention
You can drop all raw data older than 30 days while keeping your hourly/daily RollUp Tables forever. Aggregates are tiny compared to raw data, and RollUps are stored separately in `_rollup_*` tables.
:::

See [How Tiering & Retention Works](../guides/how-it-works/tiering-and-retention.md) for the internals, including the CDF durability gate.

## Choosing `tier_after` and `drop_after`

The two horizons answer different questions:

- **`tier_after`** — *how long do you need fast (sub-10 ms) Lakebase reads for this data?* Set it to the age beyond which queries are rare or latency-tolerant. It only validates and flags; nothing leaves Lakebase, so erring slightly long is cheap.
- **`drop_after`** — *how long should the data stay resident in Lakebase at all?* This is the point where the partition is actually dropped and storage is reclaimed.

The **gap** between them, `[tier_after, drop_after]`, is a buffer in which data is both hot in Lakebase *and* confirmed durable in Unity Catalog. Two rules size it:

1. **`drop_after` must exceed your maximum expected data lateness.** A late row whose partition has already been dropped is rejected by Lakebase (the window was reclaimed) and must instead be backfilled through the lakehouse. As long as `drop_after` is larger than how late data can realistically arrive, late rows land in a resident partition and are corrected automatically. **Rule of thumb: `drop_after ≥ tier_after + (your worst-case lateness / backfill window)`.**
2. **Leave headroom for CDF to catch up.** The drop is gated on CDF durability, so if the sync lags, drops simply defer (no data loss) — but a larger gap means storage is reclaimed predictably rather than stalling. Minutes of CDF lag against a multi-day `drop_after` is a non-issue.

Keep both comfortably larger than the chunk interval (at least a few chunks) so whole chunks age out cleanly, and remember `tier_after < drop_after` is enforced.

| Workload | Lateness profile | Suggested `tier_after` | Suggested `drop_after` |
|---|---|---|---|
| Metrics / logs / observability (append-only) | rarely late | 7 days | 30–90 days |
| IoT / sensors with intermittently-offline devices | up to ~N days late | 14 days | `≥ 14 days + N` (e.g. 45–60 days) |
| Financial / audit (frequent historical corrections) | corrections common, must stay queryable hot | 30 days | 180–365 days |
| Short-lived operational data, no cold copy needed | n/a | — (use plain `add_retention_policy`) | as required |

When in doubt, start with a **generous `drop_after`** (storage is cheaper to reclaim later than data is to recover) and tighten it once you've observed your real lateness distribution.

## Late arrivals and backfills

LakeTS corrects late or backfilled data automatically **as long as the target window is still resident in Lakebase** (chunk status `active` or `tiered`):

- **Late `INSERT`s and bulk `COPY`** are caught by a statement-level trigger that flags the affected RollUp buckets; the next refresh re-aggregates only those buckets from Lakebase. **Use `COPY` for bulk backfills** — it's handled correctly even though it bypasses per-row triggers.
- **`UPDATE`/`DELETE` corrections** to resident data flag their buckets via the per-row trigger and are likewise re-aggregated hot.
- **Tiering won't prematurely drop a backfilled chunk:** a late write bumps the chunk's write position, and retention re-checks the durability gate at drop time, so the chunk defers until CDF has flushed the new data to Unity Catalog.

RollUps refresh only from Lakebase-resident source data. Once a window has been **dropped** from Lakebase (status `dropped`, data only in Unity Catalog), its buckets are no longer re-aggregated — the RollUp keeps its last computed value. `invalidate_rollup_range('<rollup>', '<from>', '<to>')` silently skips buckets whose source partition has been dropped. Correct the data in the lakehouse if needed, but the RollUp will not reflect changes to source data that is no longer resident in Lakebase.

Best practices:

- **Size `drop_after` to your lateness window** (above) so late data lands in a resident partition and is re-aggregated automatically before its source is dropped.
- **Avoid `p_force` on `execute_retention`** unless you accept that un-validated data may not yet be in Unity Catalog — it bypasses the durability gate.
- **Watch `show_tiering_status`** (`cdf_status`, `caught_up`, `pending_chunks`): if CDF lags, drops defer and the hot tier grows, but no data is lost.
