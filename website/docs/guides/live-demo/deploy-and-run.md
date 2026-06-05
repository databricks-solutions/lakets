---
title: Deploy & run
sidebar_label: Deploy & run
sidebar_position: 5
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

## Step 5 — Deploy the jobs

This deploys five serverless jobs: `stream_ticks` (continuous), `partition_manager`,
`rollup_refresh`, `tiering`, and `retention`.

<Tabs>
<TabItem value="dev" label="dev — runs as you" default>

Jobs are prefixed with your name and run as you; schedules are paused, so you start
runs explicitly.

```bash
cd demo/live/bundle

databricks bundle deploy -t dev \
  --var="lakebase_project=$PROJECT" -p $PROFILE
```

</TabItem>
<TabItem value="prod" label="prod — service principal">

Jobs run as a service principal that owns a Lakebase Postgres role with the required
privileges.

```bash
cd demo/live/bundle

databricks bundle deploy -t prod \
  --var="lakebase_project=$PROJECT" \
  --var="service_principal_name=<service-principal-application-id>" -p $PROFILE
```

</TabItem>
</Tabs>

---

---

## Step 6 — Start the stream and watch it move

Start the continuous generator:

```bash
databricks bundle run lakets_demo_stream_ticks -t dev \
  --var="lakebase_project=$PROJECT" -p $PROFILE
```

Within a minute or two, ticks flow and the downstream triggers populate the cache,
the invalidation log, and the CDF shadow. Trigger a RollUp refresh on demand to see
the cascade do its work:

```bash
databricks bundle run lakets_demo_rollup_refresh -t dev \
  --var="lakebase_project=$PROJECT" -p $PROFILE
```

Inspect the hot tier directly while it runs:

```sql
-- Partitions, with status
SELECT * FROM lakets.show_chunks('stock_ticks') ORDER BY range_start;

-- Latest price per symbol, served from the cache
SELECT symbol, price, volume FROM public._lvc_stock_ticks ORDER BY symbol;

-- Minute candles
SELECT * FROM public._rollup_ohlcv_1min ORDER BY bucket DESC LIMIT 20;

-- RollUp watermarks advancing
SELECT name, watermark FROM lakets._rollup_registry ORDER BY name;

-- Dirty buckets waiting for the next refresh
SELECT count(*) FROM lakets._rollup_invalidation_log;

-- Rows mirrored to the shadow (and onward to Unity Catalog via CDF)
SELECT count(*) FROM lakets_cdf._shadow_stock_ticks;
```

Retention drops a hot partition only after `drop_after` and
the durability gate confirms the lakehouse has it, so plan to run the demo long
enough to cross that threshold, or lower the thresholds in `setup.sql`.

### Mid-demo knobs

Re-deploy with different values, or edit the `stream_ticks` job widgets in the
workspace and re-run:

| Knob | Effect |
| --- | --- |
| `symbols_count` | Widens the cache and the RollUp cardinality. |
| `rows_per_sec` | Changes the ingest rate. |
| `burst_mode` | Periodically pushes a large extra batch, so the invalidation log visibly spikes. |

---
