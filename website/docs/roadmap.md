---
title: Roadmap
sidebar_label: Roadmap
sidebar_position: 91
description: Where LakeTS is headed — the analytical time-series layer, cold-tier modeling, and the platform simplifications that land as Lakebase evolves.
---

# Roadmap

This roadmap is directional, not a commitment; priorities and timing will change. Items
are grouped by theme and tagged by rough priority. Several address entries on the
[Limitations](./limitations.md) page.

## Analytical time-series layer

LakeTS today covers shaping, aggregation, and lifecycle. The largest gap is an analytical
layer for detection and modeling. The plan is to build it hot-tier-first in PL/pgSQL for
work that fits a row engine, and push heavier work to the cold Delta tier via Spark.

- **P0 — Array primitives and `make_series`.** A dense, regular-grid series builder
  (gap-filled via `time_bucket` and `time_bucket_gapfill`) that returns numeric arrays,
  the foundation every series function depends on.
- **P0 — `series_outliers`, `series_stats`, moving aggregates.** Pure-SQL robust outlier
  scoring (median/MAD, Tukey) and summary statistics over a series array.
- **P0 — `series_decompose_anomalies`.** A seasonal-baseline and residual outlier detector
  that returns anomaly flags and scores, wired into `alert_check`.
- **P1 — Regression, correlation, and FIR/IIR filters.** `series_fit_line` and curve fits,
  Pearson and cosine correlation, and smoothing filters over arrays.
- **P1 — ASOF joins, time-window joins, and sessionization.** As-of joins and gap-based
  session windows for event-style analytics.
- **P2 — Forecasting and full decomposition at the cold tier.** STL decomposition,
  ARIMA and Prophet-style forecasting, and clustering, run as Spark jobs over the Unity
  Catalog data.

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
