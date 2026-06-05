---
title: Roadmap
sidebar_label: Roadmap
sidebar_position: 91
description: Where LakeTS is headed — cold-tier and CDF improvements and the platform simplifications that land as Lakebase evolves.
---

# Roadmap

This roadmap is directional, not a commitment; priorities and timing will change. Items
are grouped by theme and tagged by rough priority. Several address entries on the
[Limitations](./limitations.md) page.

## Cold tier and CDF

- **Retire the shadow workaround.** The unpartitioned `lakets_cdf` shadow exists only
  because Lakebase CDF cannot sync partitioned tables. When that limitation is lifted, the
  shadow layer can be torn down for direct sync.
- **First-class re-heating.** Helpers for re-ingesting cold data from Unity Catalog back
  into Lakebase.

## Platform simplification

- **Adopt native `pg_cron` and `pg_partman`.** The serverless maintenance jobs exist
  because Lakebase does not expose `pg_cron`. When these extensions are available,
  partitioning, RollUp refresh, tiering, and retention become in-database scheduled calls,
  and the external jobs are retired.

---

Have a request or a use case that should shape priorities? Open an issue on the
[GitHub repository](https://github.com/databricks-solutions/lakets).
