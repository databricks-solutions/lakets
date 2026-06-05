---
title: How it works
sidebar_label: How it works
sidebar_position: 6
---

import useBaseUrl from '@docusaurus/useBaseUrl';

## How each piece works

### Ingest — `stream_ticks`

- A continuous notebook job. It loads symbols from `stock_assets`, then loops:
  synthesize ticks (a sinusoidal intraday price path per symbol, plus noise) and
  batch-insert them into `stock_ticks`.
- Every insert is what drives the rest of the system — it routes to a partition and
  fires the LVC, invalidation, and CDF-mirror triggers.
- Widgets for symbol count, rows per second, and burst mode let you change the
  ingest profile live.

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/ingest-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/ingest.mp4')} type="video/mp4" />
</video>

### Partitioning — ChronoTables and `partition_manager`

Two pieces share the work: the **ChronoTable** owns the layout, and the
**`partition_manager`** job keeps it provisioned ahead of the stream.

- **ChronoTable (`stock_ticks`)** — a time-partitioned table created with
  `create_chronotable`, using one-hour chunks so partition creation is visible inside a
  short demo. Postgres range partitioning routes each insert to the partition covering
  its timestamp; no row is ever scanned against the wrong hour.
- **`partition_manager`** — a partition must exist before a row can land in it. This job
  runs on a schedule and calls `_ensure_partitions()`, which pre-creates a rolling window
  of future partitions so the stream always has a home and writes never stall.

You watch the active partition count climb as time advances.

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/partitioning-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/partitioning.mp4')} type="video/mp4" />
</video>

### Aggregation — the RollUp DAG and cascade refresh

The demo defines three RollUps as a dependency graph, each candle level built from
the one below it:

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/rollups-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/rollups.mp4')} type="video/mp4" />
</video>

| RollUp | Bucket | Reads from |
| --- | --- | --- |
| `ohlcv_1min` | 1 minute | raw `stock_ticks` |
| `ohlcv_1hour` | 1 hour | `ohlcv_1min` |
| `ohlcv_1day` | 1 day | `ohlcv_1hour` |

Each RollUp maintains a materialized table and a **watermark** marking how far it
has aggregated. Two mechanisms keep them current:

- **Watermark advance** — new buckets above the watermark are aggregated on each refresh.
- **Invalidation** — when historical rows change, an invalidation trigger records the
  affected buckets in `_rollup_invalidation_log`, and those buckets are re-aggregated
  on the next refresh, then cleared from the log.

The `rollup_refresh` job calls `refresh_rollup_cascade()`:

- It refreshes the graph in **topological order** — children before parents — so
  `ohlcv_1hour` reads a freshly-refreshed `ohlcv_1min`, and `ohlcv_1day` reads a
  freshly-refreshed `ohlcv_1hour`, within a single run. (A naive alphabetical pass
  would refresh `ohlcv_1day` first, off stale children.)
- Each RollUp self-gates on its `refresh_lag`, which the demo sets to zero so every
  scheduled cascade does work.

You watch the invalidation log fill continuously from the stream and drop toward zero
on each refresh, while the three watermarks advance.

### Latest value — the Last Value Cache

- `enable_lvc` installs a trigger and a compact cache table keyed by symbol.
- On every insert the trigger upserts the latest price and volume for that symbol.
- Reading the current price is then a single-row primary-key lookup — sub-10ms, with
  no job involved and no scan of the raw data.

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/lvc-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/lvc.mp4')} type="video/mp4" />
</video>

### Cold tier — the CDF shadow and Unity Catalog sync

- Lakebase CDF can't sync a partitioned table, so LakeTS keeps an unpartitioned
  **shadow** of `stock_ticks` in the `lakets_cdf` schema, fed by a true-mirror trigger
  (insert mirrors to insert, update to update, delete to delete) with full replica
  identity. `enable_sync` creates the shadow and trigger.
- Lakebase CDF then syncs the shadow to a Unity Catalog Managed Table
  continuously.
- The shadow row count tracks the raw table and the lakehouse copy grows in lockstep —
  the cold tier is always a faithful, query-ready mirror of the hot data.

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/coldtier-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/coldtier.mp4')} type="video/mp4" />
</video>

### Reclaiming the hot tier — tiering and retention

Two policies govern the lifecycle, both set by `add_tiered_retention_policy`:

- **`tier_after`** — the age at which a chunk's data is expected to be flushed to the
  lakehouse.
- **`drop_after`** — the age at which the hot partition may be dropped to reclaim
  Lakebase storage.

The `tiering` job calls `tier_chunk()` for each eligible chunk:

- **Durability gate** — a hot partition is dropped only when Lakebase CDF confirms
  every write to that chunk has already been flushed to Unity Catalog.
- **Fail-closed** — if the gate can't be satisfied, the job defers and retries on the
  next run rather than risk data that isn't safe in the lakehouse yet.

The `retention` job enforces `drop_after` via `execute_retention()`. Because the cold
tier preserves history independently, dropping a hot partition shrinks Lakebase
without losing anything from the lakehouse.

<video
  autoPlay loop muted playsInline
  poster={useBaseUrl('/video/tiering-poster.png')}
  style={{ width: '100%', borderRadius: '0.75rem', margin: '1.5rem 0', border: '1px solid rgba(127,127,127,0.18)' }}
>
  <source src={useBaseUrl('/video/tiering.mp4')} type="video/mp4" />
</video>

---
