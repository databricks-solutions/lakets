# Databricks notebook source
# MAGIC %md
# MAGIC # LakeTS Live Demo — Streaming Tick Generator
# MAGIC
# MAGIC Continuously writes synthetic ticks to `stock_ticks` on a **Lakebase
# MAGIC Autoscaling** project. Fires every downstream feature: rollup invalidation
# MAGIC triggers, LVC upserts, the CDF shadow, and Unity Catalog sync.
# MAGIC
# MAGIC **Runs on serverless compute.** Authenticates with machine-to-machine OAuth
# MAGIC (the job's service principal / your identity) — no static password. Change
# MAGIC the widgets and re-run to scale the ingest rate mid-demo.

# COMMAND ----------

# MAGIC %pip install "psycopg[binary]>=3.1,<4.0" "databricks-sdk>=0.81.0,<1.0.0"
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

dbutils.widgets.text("lakebase_project", "", "Lakebase Autoscaling project name")
dbutils.widgets.text("pg_database",      "databricks_postgres", "Database")
dbutils.widgets.dropdown("symbols_count", "10",  ["10", "100", "1000"], "Symbols")
dbutils.widgets.dropdown("rows_per_sec",  "10",  ["1", "10", "100", "1000"], "Rows/sec")
dbutils.widgets.dropdown("burst_mode",    "off", ["off", "on"], "Burst mode")
dbutils.widgets.text("duration_minutes",  "0",   "Duration (min, 0=forever)")

PROJECT          = dbutils.widgets.get("lakebase_project")
PG_DATABASE      = dbutils.widgets.get("pg_database")
SYMBOLS_COUNT    = int(dbutils.widgets.get("symbols_count"))
ROWS_PER_SEC     = int(dbutils.widgets.get("rows_per_sec"))
BURST_MODE       = dbutils.widgets.get("burst_mode") == "on"
DURATION_MINUTES = int(dbutils.widgets.get("duration_minutes"))

if not PROJECT:
    raise RuntimeError("lakebase_project widget is required (the Autoscaling project name)")
print(f"project={PROJECT} db={PG_DATABASE} symbols={SYMBOLS_COUNT} "
      f"rows/s={ROWS_PER_SEC} burst={BURST_MODE} duration_min={DURATION_MINUTES}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Lakebase Autoscaling connection (M2M OAuth)
# MAGIC Mirrors `databricks/workflows/lakebase_utils.py`: resolve the project's
# MAGIC primary read-write endpoint, read its host, and mint a short-lived OAuth
# MAGIC credential used as the Postgres password. A single long-lived connection
# MAGIC outlives the ~1h token (expiry is enforced only at login); if the job
# MAGIC restarts it reconnects with a fresh token.

# COMMAND ----------

import math
import os
import random
import time
from datetime import datetime, timezone

import psycopg
from databricks.sdk import WorkspaceClient

_w = WorkspaceClient()


def _resolve_endpoint(project_name):
    explicit = os.environ.get("LAKETS_LAKEBASE_ENDPOINT")
    if explicit:
        return explicit
    project = project_name if project_name.startswith("projects/") else f"projects/{project_name}"
    branch = f"{project}/branches/production"
    try:
        default = next((b for b in _w.postgres.list_branches(parent=project)
                        if getattr(getattr(b, "status", None), "default", False)), None)
        if default and getattr(default, "name", None):
            branch = default.name
    except Exception:
        pass
    endpoints = list(_w.postgres.list_endpoints(parent=branch))
    if not endpoints:
        raise RuntimeError(f"No Lakebase endpoints found under {branch}")
    def _rw(e):
        et = getattr(e, "endpoint_type", None) or getattr(getattr(e, "spec", None), "endpoint_type", None)
        return "READ_WRITE" in str(et)
    return next((e for e in endpoints if _rw(e)), endpoints[0]).name


_ENDPOINT = _resolve_endpoint(PROJECT)
_HOST = _w.postgres.get_endpoint(name=_ENDPOINT).status.hosts.host
_PG_ROLE = os.environ.get("LAKETS_PG_ROLE") or _w.current_user.me().user_name
print(f"endpoint={_ENDPOINT}\nhost={_HOST}\nrole={_PG_ROLE}")


def connect():
    cred = _w.postgres.generate_database_credential(endpoint=_ENDPOINT)
    conn = psycopg.connect(
        host=_HOST,
        port=5432,
        dbname=PG_DATABASE,
        user=_PG_ROLE,
        password=cred.token,
        sslmode="require",
        connect_timeout=30,
        options="-c statement_timeout=30000",
        autocommit=True,
    )
    return conn


def load_symbols(conn, limit):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT symbol, base_price, volatility "
            "FROM stock_assets ORDER BY symbol LIMIT %s",
            (limit,),
        )
        rows = cur.fetchall()
    if not rows:
        raise RuntimeError("stock_assets is empty — run sql/setup.sql first")
    return [{"symbol": r[0], "base_price": float(r[1]), "volatility": float(r[2])} for r in rows]


def synth_tick(sym, t_epoch):
    phase = (t_epoch % 3600) / 3600.0 * 2 * math.pi
    noise = (random.random() - 0.5) * 0.005
    price = sym["base_price"] * (1.0 + sym["volatility"] * math.sin(phase) + noise)
    volume = random.uniform(1000.0, 6000.0)
    return (datetime.fromtimestamp(t_epoch, tz=timezone.utc), sym["symbol"],
            round(price, 4), round(volume, 2))


def batch_insert(conn, rows):
    # psycopg3 executemany is pipelined and fast enough for demo rates.
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO stock_ticks (time, symbol, price, volume) VALUES (%s, %s, %s, %s)",
            rows,
        )

# COMMAND ----------

conn = connect()
symbols = load_symbols(conn, SYMBOLS_COUNT)
print(f"Loaded {len(symbols)} symbols: "
      f"{[s['symbol'] for s in symbols[:10]]}{'...' if len(symbols) > 10 else ''}")

# COMMAND ----------

started    = time.time()
end_at     = started + DURATION_MINUTES * 60 if DURATION_MINUTES > 0 else None
total      = 0
last_burst = started

try:
    while True:
        if end_at and time.time() >= end_at:
            print(f"Duration reached ({DURATION_MINUTES} min). Stopping.")
            break

        t_epoch = int(time.time())
        rows = [synth_tick(random.choice(symbols), t_epoch) for _ in range(ROWS_PER_SEC)]
        batch_insert(conn, rows)
        total += len(rows)

        if BURST_MODE and (time.time() - last_burst) >= 60:
            burst_rows = [synth_tick(random.choice(symbols), t_epoch) for _ in range(10_000)]
            batch_insert(conn, burst_rows)
            total += len(burst_rows)
            last_burst = time.time()
            print(f"  [burst] +10k rows  total={total:,}")

        if total % max(ROWS_PER_SEC * 30, 100) < ROWS_PER_SEC:
            elapsed = time.time() - started
            rate = total / elapsed if elapsed else 0
            print(f"  elapsed={elapsed:6.0f}s  total={total:>10,}  rate={rate:6.1f}/s")

        time.sleep(1.0)
finally:
    try:
        conn.close()
    except Exception:
        pass
    print(f"Ingest stopped. Total rows written: {total:,}")
