"""
LakeTS Benchmark Suite
Adapted from TSBS (Time Series Benchmark Suite) patterns for Lakebase.

Benchmarks:
  1. Ingest: Bulk insert throughput
  2. Simple Query: Last value per device
  3. Aggregation: Hourly rollups
  4. Gap-Fill: time_bucket_gapfill with interpolation
  5. High Cardinality: 10K+ unique series
  6. Concurrent Load: Mixed read/write

Usage:
  python run_benchmark.py --instance lakets-timeseries --rows 1000000
"""
import argparse
import json
import statistics
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import psycopg2
from databricks.sdk import WorkspaceClient


@dataclass
class BenchmarkResult:
    name: str
    duration_seconds: float
    rows_processed: int
    metric_value: float
    metric_unit: str
    details: dict = field(default_factory=dict)


def get_connection(instance_name: str):
    w = WorkspaceClient()
    cred = w.database.generate_database_credential(
        instance_names=[instance_name], request_id=str(uuid.uuid4())
    )
    inst = w.database.get_database_instance(name=instance_name)
    conn = psycopg2.connect(
        host=inst.read_write_dns, port=5432, dbname="databricks_postgres",
        user=w.current_user.me().user_name, password=cred.token, sslmode="require",
    )
    conn.autocommit = True
    return conn


@contextmanager
def timer():
    """Context manager that yields a dict with elapsed time."""
    result = {"elapsed": 0.0}
    start = time.perf_counter()
    yield result
    result["elapsed"] = time.perf_counter() - start


def setup_benchmark_table(cur, num_rows: int, num_devices: int = 100):
    """Create and populate the benchmark hypertable."""
    cur.execute("DROP TABLE IF EXISTS public.bench_metrics CASCADE;")
    cur.execute("""
        DELETE FROM lakets._chunk_metadata WHERE hypertable_id IN (
            SELECT id FROM lakets._hypertable_registry WHERE table_name = 'bench_metrics');
        DELETE FROM lakets._hypertable_registry WHERE table_name = 'bench_metrics';
    """)
    cur.execute("""
        CREATE TABLE public.bench_metrics (
            time TIMESTAMPTZ NOT NULL,
            device_id TEXT NOT NULL,
            cpu DOUBLE PRECISION,
            memory DOUBLE PRECISION,
            disk_io DOUBLE PRECISION
        );
    """)
    cur.execute(f"""
        INSERT INTO bench_metrics (time, device_id, cpu, memory, disk_io)
        SELECT
            now() - ((i * 10) || ' seconds')::interval,
            'device_' || (i % {num_devices}),
            50 + 30 * sin(i::float / 100),
            40 + 20 * cos(i::float / 200),
            random() * 1000
        FROM generate_series(1, {num_rows}) AS s(i);
    """)
    cur.execute("SELECT lakets.create_hypertable('bench_metrics', 'time', '1 day');")


def bench_ingest(cur, num_rows: int) -> BenchmarkResult:
    """Benchmark: bulk insert throughput."""
    cur.execute("DROP TABLE IF EXISTS public.bench_ingest_tmp;")
    cur.execute("""
        CREATE TABLE public.bench_ingest_tmp (
            time TIMESTAMPTZ NOT NULL, device_id TEXT, value DOUBLE PRECISION
        );
    """)

    with timer() as t:
        cur.execute(f"""
            INSERT INTO bench_ingest_tmp (time, device_id, value)
            SELECT now() - (i || ' seconds')::interval, 'dev_' || (i % 100), random() * 100
            FROM generate_series(1, {num_rows}) AS s(i);
        """)

    rows_per_sec = num_rows / t["elapsed"]
    cur.execute("DROP TABLE public.bench_ingest_tmp;")

    return BenchmarkResult(
        name="Ingest", duration_seconds=t["elapsed"], rows_processed=num_rows,
        metric_value=rows_per_sec, metric_unit="rows/sec",
    )


def bench_simple_query(cur) -> BenchmarkResult:
    """Benchmark: last value per device."""
    latencies = []
    for _ in range(10):
        with timer() as t:
            cur.execute("""
                SELECT device_id, lakets.last(cpu, time)
                FROM bench_metrics GROUP BY device_id;
            """)
            cur.fetchall()
        latencies.append(t["elapsed"] * 1000)

    return BenchmarkResult(
        name="Simple Query (last per device)", duration_seconds=sum(latencies) / 1000,
        rows_processed=10, metric_value=statistics.median(latencies),
        metric_unit="ms (median)",
        details={"p50": statistics.median(latencies), "p95": sorted(latencies)[8]},
    )


def bench_aggregation(cur) -> BenchmarkResult:
    """Benchmark: hourly rollups."""
    with timer() as t:
        cur.execute("""
            SELECT lakets.time_bucket('1 hour'::interval, time) as bucket,
                   device_id, avg(cpu), min(memory), max(disk_io), count(*)
            FROM bench_metrics
            GROUP BY 1, 2
            ORDER BY 1, 2;
        """)
        rows = cur.fetchall()

    return BenchmarkResult(
        name="Aggregation (hourly rollup)", duration_seconds=t["elapsed"],
        rows_processed=len(rows), metric_value=t["elapsed"] * 1000,
        metric_unit="ms",
    )


def bench_gapfill(cur) -> BenchmarkResult:
    """Benchmark: time_bucket_gapfill with locf."""
    with timer() as t:
        cur.execute("""
            WITH buckets AS (
                SELECT b FROM lakets.time_bucket_gapfill(
                    '1 hour'::interval,
                    now() - interval '7 days',
                    now()
                ) b
            ),
            data AS (
                SELECT lakets.time_bucket('1 hour'::interval, time) as bucket,
                       avg(cpu) as avg_cpu
                FROM bench_metrics
                WHERE device_id = 'device_0'
                GROUP BY 1
            )
            SELECT b.b as bucket,
                   lakets.locf(d.avg_cpu, LAG(d.avg_cpu) OVER (ORDER BY b.b)) as cpu
            FROM buckets b
            LEFT JOIN data d ON b.b = d.bucket
            ORDER BY b.b;
        """)
        rows = cur.fetchall()

    return BenchmarkResult(
        name="Gap-Fill (hourly LOCF)", duration_seconds=t["elapsed"],
        rows_processed=len(rows), metric_value=t["elapsed"] * 1000,
        metric_unit="ms",
    )


def bench_rollup(cur) -> BenchmarkResult:
    """Benchmark: RollUp create + incremental refresh."""
    cur.execute("DROP VIEW IF EXISTS public._rollup_rt_bench_hourly;")
    cur.execute("DROP TABLE IF EXISTS public._rollup_bench_hourly;")
    cur.execute("""
        DELETE FROM lakets._rollup_invalidation_log WHERE rollup_id IN (
            SELECT id FROM lakets._rollup_registry WHERE name = 'bench_hourly');
    """)
    cur.execute("DELETE FROM lakets._rollup_registry WHERE name = 'bench_hourly';")

    with timer() as t:
        cur.execute("""
            SELECT lakets.create_rollup(
                'bench_hourly',
                $q$SELECT lakets.time_bucket('1 hour'::interval, time) as bucket,
                         count(*) as cnt, round(avg(cpu)::numeric, 2) as avg_cpu
                  FROM bench_metrics GROUP BY 1$q$,
                '1 hour', 'bench_metrics'
            );
        """)

    create_time = t["elapsed"]

    cur.execute("UPDATE lakets._rollup_registry SET refresh_lag = '0 seconds' WHERE name = 'bench_hourly';")
    with timer() as t:
        cur.execute("SELECT lakets.refresh_rollup('bench_hourly');")

    refresh_time = t["elapsed"]

    cur.execute("SELECT lakets.drop_rollup('bench_hourly');")

    return BenchmarkResult(
        name="RollUp", duration_seconds=create_time + refresh_time,
        rows_processed=1, metric_value=refresh_time * 1000,
        metric_unit="ms (refresh)",
        details={"create_ms": create_time * 1000, "refresh_ms": refresh_time * 1000},
    )


def run_all(instance_name: str, num_rows: int):
    """Run all benchmarks and print results."""
    conn = get_connection(instance_name)
    cur = conn.cursor()

    print(f"Setting up benchmark table ({num_rows:,} rows)...")
    with timer() as t:
        setup_benchmark_table(cur, num_rows)
    print(f"Setup complete in {t['elapsed']:.1f}s\n")

    results = []
    benchmarks = [
        lambda: bench_ingest(cur, num_rows),
        lambda: bench_simple_query(cur),
        lambda: bench_aggregation(cur),
        lambda: bench_gapfill(cur),
        lambda: bench_rollup(cur),
    ]

    for bench_fn in benchmarks:
        result = bench_fn()
        results.append(result)
        print(f"  {result.name}: {result.metric_value:,.2f} {result.metric_unit} ({result.duration_seconds:.2f}s)")

    # Cleanup
    cur.execute("DROP TABLE IF EXISTS public.bench_metrics CASCADE;")
    cur.execute("""
        DELETE FROM lakets._chunk_metadata WHERE hypertable_id IN (
            SELECT id FROM lakets._hypertable_registry WHERE table_name = 'bench_metrics');
        DELETE FROM lakets._hypertable_registry WHERE table_name = 'bench_metrics';
    """)
    cur.close()
    conn.close()

    # Output JSON results
    output = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "instance": instance_name,
        "num_rows": num_rows,
        "results": [
            {
                "name": r.name,
                "duration_s": round(r.duration_seconds, 4),
                "rows": r.rows_processed,
                "value": round(r.metric_value, 2),
                "unit": r.metric_unit,
                "details": r.details,
            }
            for r in results
        ],
    }
    print(f"\n{json.dumps(output, indent=2)}")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LakeTS Benchmark Suite")
    parser.add_argument("--instance", default="lakets-timeseries", help="Lakebase instance name")
    parser.add_argument("--rows", type=int, default=100000, help="Number of rows for benchmarks")
    args = parser.parse_args()
    run_all(args.instance, args.rows)
