# LakeTS Live Demo — Grafana

A local Grafana stack with two datasources:

- **Lakebase (hot tier)** — Postgres datasource, queries `stock_ticks`, the LVC,
  the RollUp tables, `lakets.show_chunks`, the invalidation log, etc.
- **Databricks (cold tier)** — the community `mullerpeter-databricks-datasource`
  plugin, queries the Unity Catalog Managed Table that Lakebase CDF syncs from
  `lakets_cdf._shadow_stock_ticks`.

Dashboards (`dashboards/`): `lakets_live.json` (hot, fast refresh),
`lakets_cold_tier.json` (cold / UC), `lakets_continuum.json` (hot + cold combined).

## Run

```bash
cp .env.example .env     # fill in the values below
podman compose --env-file .env up -d    # or: docker compose
# open http://localhost:3030  (anonymous Viewer enabled)
```

## Auth model (important on Autoscaling)

The jobs authenticate with rotating **M2M OAuth**, but Grafana's Postgres
datasource can't refresh a token, so the **hot tier needs a static login**:

1. Enable native Postgres login on the project (one-time):
   ```bash
   databricks postgres update-project projects/<project> \
     --json '{"spec":{"enable_pg_native_login":true}}' -p <profile>
   ```
2. As a Lakebase admin, create a least-privilege role for Grafana and a password:
   ```sql
   CREATE ROLE grafana LOGIN PASSWORD '<strong-password>';
   GRANT USAGE ON SCHEMA public, lakets TO grafana;
   GRANT SELECT ON ALL TABLES IN SCHEMA public, lakets TO grafana;
   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lakets TO grafana;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
   ```
3. Put that host / user / password in `.env` (`LAKEBASE_*`).

The **cold tier** uses a Databricks **SQL warehouse** + a token. Prefer a
service-principal-owned token so audit logs attribute Grafana queries to the SP,
not your user. Set `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN`,
and `DELTA_TABLE` (the UC table CDF syncs into). Leave them blank to run only the
hot-tier dashboard.

## Notes

- The `mullerpeter-databricks-datasource` plugin is delisted from the Grafana
  catalog but still maintained; it installs unsigned from its GitHub release via
  `GF_INSTALL_PLUGINS` in `docker-compose.yml`.
- `.env` is gitignored — never commit credentials.
