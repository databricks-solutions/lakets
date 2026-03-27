# LakeTS Migrations

This directory contains SQL migration scripts for breaking changes between versions.

## When migrations are needed

LakeTS modules are idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`), so most upgrades
just require re-running the install. Migrations are only needed when:

1. A table column is renamed or dropped
2. A function signature changes (different parameter count/types)
3. Data transformation is required between versions

## Naming convention

```
migrations/v{from}_to_v{to}.sql
```

Example: `migrations/v0.1.0_to_v0.2.0.sql`

## Usage

```bash
# Run the migration first, then reinstall
psql -f migrations/v0.1.0_to_v0.2.0.sql
psql -f dist/lakets.sql
```
