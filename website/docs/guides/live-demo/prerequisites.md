---
title: Prerequisites
sidebar_position: 2
---

Before you begin, make sure you have:

- A **Lakebase Autoscaling project** accessible from both the Databricks UI and CLI.
  Commands identify it by project name, not by host.
- The **Databricks CLI**, authenticated with a profile for that workspace.
- **`psql`** available on your `PATH` for the SQL steps.
- **Podman or Docker** with the compose plugin — required only for the optional
  Grafana dashboards.

Lakebase CDF is enabled later, in [Step 4](./enable-cdf.md), rather than beforehand.
It operates on the `lakets_cdf` schema and its shadow table, both of which LakeTS
provisions for you: the schema during [install](./setup.md), and the shadow when
`enable_sync` runs during [setup](./setup.md).

:::note Authentication

No static passwords are required. The jobs authenticate with machine-to-machine OAuth
automatically; for `psql`, you generate a short-lived token (covered in the next
step). Grafana is the exception — it cannot refresh tokens, so [its setup
page](./grafana.md) describes the alternative.

:::
