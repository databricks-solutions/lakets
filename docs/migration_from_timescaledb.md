# Migrating from TimescaleDB to LakeTS

This guide maps TimescaleDB concepts and functions to their LakeTS equivalents.

## Function Mapping

| TimescaleDB | LakeTS | Notes |
|-------------|--------|-------|
| `create_hypertable('t', 'time')` | `lakets.create_chronotable('t', 'time')` | LakeTS uses native PG RANGE partitioning. `create_hypertable` also works (alias). |
| `set_chunk_time_interval(t, '7d')` | `lakets.set_chunk_interval('t', '7 days')` | Same semantics |
| `show_chunks('t')` | `lakets.show_chunks('t')` | Same API |
| `drop_chunks('t', older_than => '30d')` | `lakets.drop_chunks('t', '30 days')` | Named param vs positional |
| `time_bucket('1h', time)` | `lakets.time_bucket('1 hour'::interval, time)` | Requires explicit `::interval` cast |
| `time_bucket_gapfill('1h', time)` | `lakets.time_bucket_gapfill('1 hour', start, end)` | LakeTS returns a set; use with LEFT JOIN |
| `first(value, time)` | `lakets.first(value, time)` | Same. LakeTS accepts DOUBLE PRECISION only |
| `last(value, time)` | `lakets.last(value, time)` | Same. LakeTS accepts DOUBLE PRECISION only |
| `locf(value)` | `lakets.locf(value, LAG(value) OVER (...))` | LakeTS requires explicit LAG window |
| `interpolate(value)` | `lakets.interpolate(val, prev, next, prev_t, curr_t, next_t)` | LakeTS requires all 6 params explicitly |
| `add_compression_policy(t, '7d')` | `lakets.add_compression_policy('t', '7 days')` | LakeTS tiers to Delta Lake instead of in-place compression |
| `add_retention_policy(t, '30d')` | `lakets.add_retention_policy('t', '30 days')` | Same semantics |
| `CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous)` | `lakets.create_rollup(name, query)` | Function-based API; creates a regular table, not a matview |
| `refresh_continuous_aggregate(view, ...)` | `lakets.refresh_rollup(name)` | LakeTS does true incremental refresh (only dirty buckets) |
| Hierarchical continuous aggregates | `lakets.create_rollup(..., p_depends_on := ARRAY['parent'])` | DAG-based dependency ordering with `refresh_rollup_cascade()` |
| N/A | `lakets.refresh_rollup_cascade(name)` | Refreshes all dependencies in topological order |
| N/A | `lakets.enable_rollup_export(name, delta_table)` | Export RollUp Tables to Delta Lake |

## Key Differences

### 1. Gap-filling pattern

**TimescaleDB** (integrated into GROUP BY):
```sql
SELECT time_bucket_gapfill('1 hour', time) AS bucket,
       locf(avg(cpu))
FROM metrics
WHERE time BETWEEN start AND finish
GROUP BY 1;
```

**LakeTS** (LEFT JOIN pattern):
```sql
WITH buckets AS (
    SELECT b FROM lakets.time_bucket_gapfill('1 hour', start, finish) b
),
data AS (
    SELECT lakets.time_bucket('1 hour'::interval, time) AS bucket, avg(cpu) AS v
    FROM metrics GROUP BY 1
)
SELECT b.b, lakets.locf(d.v, LAG(d.v) OVER (ORDER BY b.b))
FROM buckets b LEFT JOIN data d ON b.b = d.bucket;
```

### 2. Compression is tiering

TimescaleDB compresses chunks in-place (row -> columnar). LakeTS tiers data to Delta Lake via Lakehouse Sync, then drops the Lakebase partition. The data remains queryable via Lakehouse Federation.

### 3. RollUps (replaces continuous aggregates)

TimescaleDB tracks invalidation regions via WAL and refreshes only changed buckets. LakeTS now has an equivalent capability via the **RollUp Engine**: `create_rollup()` creates a regular table (not a materialized view) with watermark-based incremental refresh — only dirty time buckets are recomputed. For real-time freshness, `create_rollup_view()` UNIONs the RollUp Table with a raw query for data beyond the watermark. For mutation tracking, `enable_rollup_invalidation()` installs an opt-in trigger that logs dirty buckets.

**New in Modules 23–28**: LakeTS now supports chunk-skip pruning (skip unmodified partitions), batch set-based refresh (2 SQL statements per batch instead of 2N), DAG-based dependency orchestration for hierarchical RollUps (`refresh_rollup_cascade()`), automatic hot/cold tier detection, bulk import invalidation (captures `COPY FROM`), and export of RollUp Tables to Delta Lake.

### 4. Type constraints

LakeTS `first()` and `last()` aggregates currently accept `DOUBLE PRECISION` only. TimescaleDB supports `anyelement`. Cast your values:
```sql
SELECT lakets.first(value::double precision, time) FROM ...
```

## Migration Steps

1. **Install LakeTS** on your Lakebase instance (see [Getting Started](getting_started.md))
2. **Export data** from TimescaleDB using `COPY` or `pg_dump --data-only`
3. **Create tables** in Lakebase with the same schema (minus TimescaleDB-specific constraints)
4. **Import data** using `COPY` or bulk INSERT
5. **Convert to ChronoTables**: `SELECT lakets.create_chronotable('table', 'time_col', 'interval')`
6. **Recreate policies**:
   - Compression: `SELECT lakets.add_compression_policy(...)`
   - Retention: `SELECT lakets.add_retention_policy(...)`
7. **Recreate aggregates as RollUps**: `SELECT lakets.create_rollup(name, query, interval, source_table)`
8. **Update application queries**: Replace `time_bucket_gapfill` pattern, add `::interval` casts
9. **Deploy Databricks workflows** for automated lifecycle management
