---
title: Upgrade LakeTS
sidebar_label: Upgrade
sidebar_position: 9
description: Move an existing LakeTS install to a newer release with the migration runner.
---

# Upgrade LakeTS

An upgrade has two parts: **schema migrations** apply the additive DDL a new release needs (new tables, columns, indexes), and **reinstalling the modules** refreshes every function and trigger to the new version. LakeTS tracks the installed version in `lakets._version`, and the migration runner applies only the migrations that move you past it.

## Check the installed version

```sql
SELECT version, installed_at FROM lakets._version ORDER BY installed_at DESC LIMIT 1;
```

## Upgrade an existing install

Run both steps against your Lakebase instance, in order:

```bash
# 1. Apply pending schema migrations (idempotent; records the new version)
psql -q -h <host> -U <user>@databricks.com -d <database> -f sql/migrate.sql

# 2. Refresh all function and trigger definitions to the new release
psql -q -h <host> -U <user>@databricks.com -d <database> -f dist/lakets.sql
```

Then verify the version advanced:

```sql
SELECT version, installed_at FROM lakets._version ORDER BY installed_at;
```

`sql/migrate.sql` reads `lakets._version`, applies each pending `migrations/V<from>_<to>_*.sql` in version order, and stops cleanly if LakeTS is not installed. Reinstalling `dist/lakets.sql` uses `CREATE OR REPLACE`, so it updates definitions in place without dropping data.

## Fresh install

If LakeTS is not installed yet, do not run the migration runner — it requires an existing version. Install the release directly instead:

```bash
psql -q -h <host> -U <user>@databricks.com -d <database> -f dist/lakets.sql
```

See the [Quickstart](../guides/getting-started.md) for the full first-install flow.

## How migrations work

- Migrations live in `migrations/V<from>_<to>_*.sql` and are applied by `sql/migrate.sql` in version order.
- Each migration is **version-guarded**: it requires the expected source version and becomes a no-op if its target version is already recorded, so re-running the runner is safe.
- Each migration is **idempotent** — `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, and similar — and records the new version in `lakets._version` on success.
- Migrations are **additive**. They add tables, columns, and indexes; they do not drop data.

## Notes

- The upgrade does not move or delete data. Tiering and retention remain CDF-gated throughout, so an in-flight upgrade cannot drop a partition that is not yet durable in Unity Catalog.
- Function and trigger definitions are replaced atomically per object by step 2; running the upgrade during a quiet window is optional, not required.
- The Databricks jobs read the same `lakets._version` and metadata, so they pick up the new behavior on their next scheduled run with no separate redeploy.
