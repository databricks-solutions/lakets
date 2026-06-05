---
title: Limitations
sidebar_label: Limitations
sidebar_position: 90
description: The constraints of LakeTS today — cold-tier / CDF restrictions, tiering and RollUp caveats, and current scheduling.
---

# Limitations

The constraints LakeTS carries today, and the limits it inherits from Lakebase CDF.
Many have a workaround that LakeTS already applies; where one exists, it is noted.
Several map directly to items on the [Roadmap](./roadmap.md).

## Cold tier and Lakebase CDF

LakeTS syncs to Unity Catalog through Lakebase CDF, which carries its own limits:

| Limitation | How LakeTS handles it |
| --- | --- |
| Partitioned tables can't be synced by CDF | An unpartitioned **shadow** in `lakets_cdf`, fed by a true-mirror trigger — created automatically by `enable_sync` |
| Sync is **one-way** (Lakebase → Unity Catalog) | Re-heat by re-ingesting from the Unity Catalog table via a Databricks job |
| Schema changes break a running sync | Re-create the shadow (`disable_sync` → `enable_sync`) and re-enable CDF |
| `PostGIS`, `pgvector`, composite types not synced | Exclude those columns from the synced table, or cast to `TEXT` |
| Empty tables are not synced | The first `INSERT` starts the sync |
| A shadow's `committed_lsn` does not advance while it is idle | Tiering gates on each chunk's own `last_write_lsn`, not the global WAL head, so an idle shadow never blocks eviction of already-flushed chunks |

- **CDF must be enabled in Databricks.** LakeTS creates the `lakets_cdf` schema and the
  shadow tables, but turning on the managed sync is a one-time Databricks UI
  step (see [Lakebase CDF setup](./guides/lakebase-cdf-setup.md)).

## Tiering and retention

- **Tiering and retention depend on CDF and are fail-closed.** A hot partition is dropped
  (by retention) only once CDF confirms its data is flushed to Unity Catalog. If CDF is
  not streaming, the drop **defers indefinitely** — LakeTS never drops data that is not yet
  safe in the lakehouse, unless you pass `p_force` to `execute_retention`.
- **Reclamation stalls if CDF stalls.** A stuck or unconfigured sync means the hot
  tier keeps growing, because un-validated chunks are never flagged or dropped.

## RollUps

- **RollUps refresh only from Lakebase-resident source data.** A bucket is recomputed
  while its source partition is still in Lakebase (`active` or `tiered`). Once the
  partition is dropped by retention, that bucket can no longer be recomputed and the
  RollUp keeps its last computed value — a correction to already-dropped source data is
  not reflected.

## Scheduling and partition management

`pg_cron` and `pg_partman` are not yet available on Lakebase, so scheduling and
partition management currently run as Databricks (Lakeflow) jobs rather than inside
the database. This is a temporary gap: LakeTS will adopt native in-database scheduling
and partition management once those extensions become available on Lakebase.
