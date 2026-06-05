---
title: Teardown
sidebar_position: 8
---

## Teardown

Remove the jobs:

```bash
cd demo/live/bundle

databricks bundle destroy -t dev \
  --var="lakebase_project=$PROJECT" -p $PROFILE
```

Reset the Lakebase state, keeping the `lakets` schema itself:

```bash
psql "$PG_URL" <<'SQL'
  SELECT lakets.disable_sync('stock_ticks');
  SELECT lakets.disable_lvc('stock_ticks');
  SELECT lakets.drop_rollup('ohlcv_1day');
  SELECT lakets.drop_rollup('ohlcv_1hour');
  SELECT lakets.drop_rollup('ohlcv_1min');
  DROP TABLE IF EXISTS stock_ticks CASCADE;
  DROP TABLE IF EXISTS stock_assets CASCADE;
  DELETE FROM lakets._chronotable_registry WHERE table_name = 'stock_ticks';
SQL
```

The Unity Catalog Managed Table that CDF populated is retained. Drop it from Catalog
Explorer if you want a full reset.
