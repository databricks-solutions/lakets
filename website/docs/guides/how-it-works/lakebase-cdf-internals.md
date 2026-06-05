---
title: Lakebase CDF internals
sidebar_label: Lakebase CDF internals
sidebar_position: 5
description: How LakeTS mirrors partitioned writes through an unpartitioned shadow table into Unity Catalog.
---

import useBaseUrl from '@docusaurus/useBaseUrl';

export const Demo = ({src, poster}) => (
  <video autoPlay loop muted playsInline poster={useBaseUrl(poster)}
    style={{ width: '100%', borderRadius: '0.75rem', margin: '1.25rem 0', border: '1px solid rgba(127,127,127,0.18)' }}>
    <source src={useBaseUrl(src)} type="video/mp4" />
  </video>
);

# How Lakebase CDF works

Lakebase CDF, built on `wal2delta`, streams changes from Lakebase into a Unity Catalog Managed Table. It has one constraint that shapes the entire design: it fails on any schema that contains a partitioned table.

## Why a shadow table

ChronoTable parents are partitioned, so CDF cannot sync them — and cannot sync the schema that holds them at all while a partitioned table is present (whatever schema that is). LakeTS therefore keeps an unpartitioned **shadow** of each synced table in a dedicated, partition-free `lakets_cdf` schema.

<Demo src="/video/cdf-constraint.mp4" poster="/video/cdf-constraint-poster.png" />

This is a deliberate, removable workaround: when Lakebase CDF gains partitioned-table support, the shadow layer can be torn down and the partitioned tables synced directly.

## The true-mirror trigger

`enable_sync('metrics')` builds the shadow (`lakets_cdf._shadow_metrics`, with `REPLICA IDENTITY FULL`) and installs an `AFTER INSERT OR UPDATE OR DELETE` trigger, `trg_lakets_sync`, on the ChronoTable parent. The trigger fires on the child partitions, so it resolves the logical parent through `_resolve_partition_parent` (a `pg_inherits` lookup) and the registry, then mirrors each change into the shadow:

<Demo src="/video/cdf-mirror.mp4" poster="/video/cdf-mirror-poster.png" />

| Source operation | Shadow operation |
| --- | --- |
| `INSERT` | `INSERT` |
| `UPDATE` | `DELETE` the old row, then `INSERT` the new row |
| `DELETE` | `DELETE` |

The shadow has no primary key, so rows are matched for `UPDATE` and `DELETE` by full-row equality (`REPLICA IDENTITY FULL` makes the complete old-row image available to both the trigger and CDC). The same dispatch serves RollUp tables, whose shadow is named `_shadow_rollup_<name>`.

## Streaming to Unity Catalog

Once the shadow is streaming, `wal2delta` replicates it to a Unity Catalog Managed Table named `lb_<shadow>_history` (for example, `lakets_cdf._shadow_metrics` → `lb__shadow_metrics_history`). The destination is an append-only change feed: an `UPDATE` mirrored as `DELETE` + `INSERT` appends both change records, so the history accumulates rather than overwriting in place.

`enable_sync` is idempotent and warns rather than errors if `wal2delta` is absent — CDF is a prerequisite enabled out-of-band on the `lakets_cdf` schema, not something LakeTS turns on itself. `disable_sync` drops the trigger and the shadow but leaves the Unity Catalog table in place, since that table is owned by CDF.

## The durability anchor for tiering

The shadow layer is not only a sync convenience. `wal2delta.tables` exposes a per-shadow `committed_lsn` that records how far CDF has flushed. [Tiering's durability gate](./tiering-and-retention.md#the-durability-gate) compares that value against each chunk's stamped write position before a chunk is flagged `tiered` or its partition is dropped, so the shadow is what makes tiering and eviction provably safe.
