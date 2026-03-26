#!/usr/bin/env python3
"""Create feature deep-dive slides: TimescaleDB features → LakeTS implementation."""

import json
import os
import sys
import time
import subprocess

sys.path.insert(0, os.path.dirname(__file__))
from slides_diagram_utils import (
    COLORS, INCH, PT, uid, get_token, batch_update,
    shape_request, style_shape, text_request, text_style,
    line_request, style_line, image_request, make_title_bar,
)

PRES_ID = "16921ABei8w5RTJ-JQTlitBVmWpDgojUfS0sy5RMxw34"
BUILDER = os.path.expanduser(
    "~/.claude/plugins/cache/fe-vibe/fe-google-tools/1.2.9/skills/google-slides/resources/gslides_builder.py"
)
ICONS_PATH = os.path.expanduser(
    "~/Documents/Claude Projects/Lakebase/timeseries/diagrams/icons/icon_urls.json"
)
with open(ICONS_PATH) as f:
    ICONS = json.load(f)

# Colors
TSDB_BLUE = {"red": 0.18, "green": 0.55, "blue": 0.78}
LAKETS_TEAL = {"red": 0.11, "green": 0.19, "blue": 0.22}
TSDB_BG = {"red": 0.91, "green": 0.95, "blue": 0.98}
LAKETS_BG = {"red": 0.90, "green": 0.96, "blue": 0.91}
CODE_BG = {"red": 0.96, "green": 0.96, "blue": 0.96}
RED = {"red": 1.0, "green": 0.21, "blue": 0.13}
WHITE = {"red": 1.0, "green": 1.0, "blue": 1.0}
DARK = {"red": 0.15, "green": 0.15, "blue": 0.15}
GREY = {"red": 0.45, "green": 0.45, "blue": 0.45}
BORDER = {"red": 0.82, "green": 0.82, "blue": 0.82}
INSIGHT_BG = {"red": 1.0, "green": 0.96, "blue": 0.94}


def _ssl_cert():
    return "/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages/certifi/cacert.pem"


def E(inches):
    """Convert inches to EMU."""
    return int(inches * INCH)


def create_blank_slide(token, slide_id=None):
    sid = slide_id or uid("fslide")
    batch_update(PRES_ID, [{
        "createSlide": {
            "objectId": sid,
            "slideLayoutReference": {"predefinedLayout": "BLANK"},
        }
    }], token)
    time.sleep(0.3)
    return sid


def add_section_slide(title, subtitle, token):
    """Add a section header using gslides_builder.py."""
    r = subprocess.run(
        ["python3", BUILDER, "add-template-slide",
         "--pres-id", PRES_ID, "--layout", "section_1col"],
        capture_output=True, text=True,
        env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
    )
    try:
        data = json.loads(r.stdout)
        page_id = data.get("pageId")
    except (json.JSONDecodeError, AttributeError):
        # Fallback: try content_basic layout
        r = subprocess.run(
            ["python3", BUILDER, "add-template-slide",
             "--pres-id", PRES_ID, "--layout", "content_basic"],
            capture_output=True, text=True,
            env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
        )
        try:
            data = json.loads(r.stdout)
            page_id = data.get("pageId")
        except Exception:
            return None

    if not page_id:
        return None

    subprocess.run(
        ["python3", BUILDER, "set-placeholder",
         "--pres-id", PRES_ID, "--page-id", page_id,
         "--type", "TITLE", "--text", title],
        capture_output=True, text=True,
        env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
    )
    subprocess.run(
        ["python3", BUILDER, "set-placeholder",
         "--pres-id", PRES_ID, "--page-id", page_id,
         "--type", "BODY", "--text", subtitle],
        capture_output=True, text=True,
        env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
    )
    time.sleep(0.3)
    return page_id


def build_feature_slide(token, slide_id, title, subtitle,
                        tsdb_title, tsdb_items,
                        lakets_title, lakets_items,
                        code_tsdb=None, code_lakets=None,
                        insight=None, tsdb_icon=None, lakets_icon=None):
    """Build a feature comparison slide with two columns using native shapes."""
    reqs = []

    # Title bar (uses make_title_bar from utils)
    reqs += make_title_bar(slide_id, title, subtitle)

    # Layout constants
    MARGIN = 0.4
    COL_W = 5.4
    GAP = 0.35
    HDR_H = 0.42
    Y_HDR = 1.15

    # ── TimescaleDB column header ──
    th = uid("th")
    reqs.append(shape_request(slide_id, th, "ROUND_RECTANGLE",
        E(MARGIN), E(Y_HDR), E(COL_W), E(HDR_H)))
    reqs.append(style_shape(th, fill_color=TSDB_BLUE))
    reqs.append(text_request(th, tsdb_title))
    reqs += text_style(th, font_size=13, bold=True, color=WHITE, alignment="CENTER")

    # ── LakeTS column header ──
    lh = uid("lh")
    reqs.append(shape_request(slide_id, lh, "ROUND_RECTANGLE",
        E(MARGIN + COL_W + GAP), E(Y_HDR), E(COL_W), E(HDR_H)))
    reqs.append(style_shape(lh, fill_color=LAKETS_TEAL))
    reqs.append(text_request(lh, lakets_title))
    reqs += text_style(lh, font_size=13, bold=True, color=WHITE, alignment="CENTER")

    # ── Icons in headers ──
    if tsdb_icon and tsdb_icon in ICONS:
        ico = uid("ico")
        reqs.append(image_request(slide_id, ico, ICONS[tsdb_icon],
            E(MARGIN + COL_W - 0.48), E(Y_HDR + 0.04), E(0.34), E(0.34)))
    if lakets_icon and lakets_icon in ICONS:
        ico = uid("ico")
        reqs.append(image_request(slide_id, ico, ICONS[lakets_icon],
            E(MARGIN + COL_W + GAP + COL_W - 0.48), E(Y_HDR + 0.04), E(0.34), E(0.34)))

    # ── Arrow between headers ──
    arr = uid("arr")
    reqs.append(line_request(slide_id, arr,
        E(MARGIN + COL_W + 0.03), E(Y_HDR + HDR_H / 2),
        E(GAP - 0.06), 0))
    reqs.append(style_line(arr, color=RED, weight=2, end_arrow="OPEN_ARROW"))

    # ── Content rows ──
    Y_START = Y_HDR + HDR_H + 0.18
    ROW_H = 0.34
    ROW_GAP = 0.06

    max_rows = max(len(tsdb_items), len(lakets_items))

    for i, item in enumerate(tsdb_items):
        y = Y_START + i * (ROW_H + ROW_GAP)
        b = uid("tb")
        reqs.append(shape_request(slide_id, b, "ROUND_RECTANGLE",
            E(MARGIN + 0.05), E(y), E(COL_W - 0.1), E(ROW_H)))
        reqs.append(style_shape(b, fill_color=TSDB_BG, stroke_color=BORDER, stroke_weight=0.5))
        reqs.append(text_request(b, item))
        reqs += text_style(b, font_size=9.5, color=DARK)

    for i, item in enumerate(lakets_items):
        y = Y_START + i * (ROW_H + ROW_GAP)
        b = uid("lb")
        reqs.append(shape_request(slide_id, b, "ROUND_RECTANGLE",
            E(MARGIN + COL_W + GAP + 0.05), E(y), E(COL_W - 0.1), E(ROW_H)))
        reqs.append(style_shape(b, fill_color=LAKETS_BG, stroke_color=BORDER, stroke_weight=0.5))
        reqs.append(text_request(b, item))
        reqs += text_style(b, font_size=9.5, color=DARK)

    # ── Code examples ──
    Y_CODE = Y_START + max_rows * (ROW_H + ROW_GAP) + 0.12
    CODE_H = 0.7

    if code_tsdb:
        c = uid("ct")
        reqs.append(shape_request(slide_id, c, "RECTANGLE",
            E(MARGIN + 0.05), E(Y_CODE), E(COL_W - 0.1), E(CODE_H)))
        reqs.append(style_shape(c, fill_color=CODE_BG, stroke_color=BORDER, stroke_weight=0.5))
        reqs.append(text_request(c, code_tsdb))
        reqs += text_style(c, font_size=7.5, color=GREY, font="Courier New")

    if code_lakets:
        c = uid("cl")
        reqs.append(shape_request(slide_id, c, "RECTANGLE",
            E(MARGIN + COL_W + GAP + 0.05), E(Y_CODE), E(COL_W - 0.1), E(CODE_H)))
        reqs.append(style_shape(c, fill_color=CODE_BG, stroke_color=BORDER, stroke_weight=0.5))
        reqs.append(text_request(c, code_lakets))
        reqs += text_style(c, font_size=7.5, color=GREY, font="Courier New")

    # ── Insight banner ──
    if insight:
        Y_INS = 6.65
        ins = uid("ins")
        reqs.append(shape_request(slide_id, ins, "ROUND_RECTANGLE",
            E(MARGIN), E(Y_INS), E(COL_W * 2 + GAP), E(0.42)))
        reqs.append(style_shape(ins, fill_color=INSIGHT_BG, stroke_color=RED, stroke_weight=1))
        reqs.append(text_request(ins, insight))
        reqs += text_style(ins, font_size=9, bold=True, color=RED, alignment="CENTER")

    return reqs


# ─── Feature definitions ───

FEATURES = [
    {
        "title": "Hypertables → ChronoTables",
        "subtitle": "Automatic time partitioning — C extension vs native Postgres",
        "tsdb_title": "TimescaleDB: Hypertables",
        "lakets_title": "LakeTS: ChronoTables",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "Custom C extension hooks into storage engine",
            "create_hypertable() — transparent chunk creation",
            "ChunkAppend optimizer for range scans",
            "Automatic chunk mgmt (background worker)",
            "Invisible to user — looks like one table",
        ],
        "lakets_items": [
            "Pure PL/pgSQL — no extension required",
            "create_chronotable() — PARTITION BY RANGE",
            "Native Postgres partition pruning + BRIN index",
            "Databricks Workflow (partition_manager.py, 6hr)",
            "Real PG partitions — explicit, inspectable",
        ],
        "code_tsdb": "-- TimescaleDB\nSELECT create_hypertable(\n  'metrics', 'time',\n  chunk_time_interval => '7 days'\n);",
        "code_lakets": "-- LakeTS\nSELECT lakets.create_chronotable(\n  'metrics', 'time', '7 days'\n);\n-- Alias: lakets.create_hypertable()",
        "insight": "Trade-off: C extension = faster but requires install. PL/pgSQL = runs on any Lakebase, zero install.",
    },
    {
        "title": "time_bucket & Hyperfunctions",
        "subtitle": "Core time-series SQL functions — C-optimized vs PL/pgSQL",
        "tsdb_title": "TimescaleDB: C Hyperfunctions",
        "lakets_title": "LakeTS: PL/pgSQL Functions",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "time_bucket() — native C, blazing fast",
            "Sub-month + month/year intervals",
            "Integrated into executor pipeline",
            "Marked IMMUTABLE for planner optimization",
        ],
        "lakets_items": [
            "time_bucket() — wraps date_bin() for sub-month",
            "Custom month-arithmetic for month/year intervals",
            "Counts months since epoch, integer-divides",
            "Also IMMUTABLE — enables partition pruning",
        ],
        "code_tsdb": "SELECT time_bucket('1 hour', time)\n  AS bucket, avg(cpu)\nFROM metrics\nGROUP BY bucket;",
        "code_lakets": "SELECT lakets.time_bucket(\n  '1 hour'::interval, time,\n  '2000-01-01'::timestamptz\n) AS bucket, avg(cpu)\nFROM metrics GROUP BY bucket;",
        "insight": "Benchmark (50K rows, CU_1): time_bucket LakeTS ~11ms vs TimescaleDB ~10ms. Near parity.",
    },
    {
        "title": "first() / last() Aggregates",
        "subtitle": "Value at earliest/latest timestamp — custom aggregate implementation",
        "tsdb_title": "TimescaleDB: C Aggregates",
        "lakets_title": "LakeTS: PL/pgSQL Aggregates",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "Native C aggregate functions",
            "Supports anyelement — any type",
            "Integrated into GroupAggregate node",
            "Extremely fast for time-ordered data",
        ],
        "lakets_items": [
            "CREATE AGGREGATE with PL/pgSQL state fns",
            "DOUBLE PRECISION only (cast for others)",
            "State: _first_last_state (value, ts)",
            "_first_sfunc keeps min ts, _last_sfunc max ts",
        ],
        "code_tsdb": "SELECT device_id,\n  first(temperature, time),\n  last(temperature, time)\nFROM readings\nGROUP BY device_id;",
        "code_lakets": "-- Same SQL interface!\nSELECT device_id,\n  lakets.first(temperature, time),\n  lakets.last(temperature, time)\nFROM readings\nGROUP BY device_id;",
        "insight": "Same API surface. Limitation: LakeTS first/last only supports DOUBLE PRECISION values.",
    },
    {
        "title": "Gap-Fill, LOCF & Interpolation",
        "subtitle": "Filling missing time-series data points — integrated vs explicit",
        "tsdb_title": "TimescaleDB: Integrated Gap-Fill",
        "lakets_title": "LakeTS: Composable Functions",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "time_bucket_gapfill() in GROUP BY",
            "Auto-generates missing time buckets",
            "locf() reads window frame implicitly",
            "interpolate() auto-detects prev/next",
        ],
        "lakets_items": [
            "time_bucket_gapfill() → generate_series()",
            "Must LEFT JOIN with data CTE explicitly",
            "locf(value, LAG(value) OVER(ORDER BY t))",
            "interpolate(val, prev, next, t0, t, t1)",
        ],
        "code_tsdb": "SELECT time_bucket_gapfill(\n  '1h', time, start, finish),\n  locf(avg(cpu))\nFROM metrics\nGROUP BY 1;",
        "code_lakets": "WITH b AS (SELECT lakets.\n  time_bucket_gapfill(...))\nSELECT b.bucket,\n  lakets.locf(d.cpu, LAG(d.cpu)\n  OVER(ORDER BY b.bucket))\nFROM b LEFT JOIN data d ON ...;",
        "insight": "Trade-off: TimescaleDB is more ergonomic. LakeTS is explicit — each function is composable and testable.",
    },
    {
        "title": "RollUps (Incremental Aggregates)",
        "subtitle": "Pre-computed rollups with incremental refresh + real-time freshness",
        "tsdb_title": "TimescaleDB: WAL-Based Refresh",
        "lakets_title": "LakeTS: Incremental RollUp Engine",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "CREATE MATERIALIZED VIEW ... WITH (continuous)",
            "WAL-based invalidation tracking",
            "Refreshes only changed time buckets",
            "Transparent real-time query layer",
            "Hierarchical caggs (cagg on cagg)",
        ],
        "lakets_items": [
            "create_rollup(name, query, interval, source)",
            "Incremental: DELETE+INSERT only dirty buckets",
            "Watermark tracks last materialized bucket",
            "create_rollup_view() → UNION ALL real-time",
            "rollup_refresh.py Databricks job (every 15 min)",
        ],
        "code_tsdb": "CREATE MATERIALIZED VIEW hourly\nWITH (timescaledb.continuous)\nAS SELECT time_bucket('1h', time),\n  avg(cpu) FROM metrics\nGROUP BY 1;",
        "code_lakets": "SELECT lakets.create_rollup(\n  'hourly',\n  'SELECT lakets.time_bucket(...)',\n  '1 hour', 'metrics'\n);\nSELECT lakets.create_rollup_view(\n  'hourly', '<raw_query>');",
        "insight": "LakeTS now has true incremental refresh — per-bucket DELETE+INSERT with invalidation log.",
    },
    {
        "title": "Compression → Delta Lake Tiering",
        "subtitle": "Data compaction — in-place columnar vs lakehouse tiering",
        "tsdb_title": "TimescaleDB: In-Place Columnar",
        "lakets_title": "LakeTS: Delta Lake Parquet",
        "tsdb_icon": "postgresql",
        "lakets_icon": "delta_lake",
        "tsdb_items": [
            "Row chunks → columnar format in-place",
            "~98% compression ratio",
            "Transparent decompress-on-read",
            "Data stays in Postgres (single engine)",
            "S3 tiering (Tiger Cloud only)",
        ],
        "lakets_items": [
            "Hot data → Delta via Lakehouse Sync CDC",
            "Parquet + Z-ORDER / Liquid Clustering",
            "compression_job.py marks & drops partitions",
            "ACID, time travel, Unity Catalog governance",
            "Query cold via Federation or Spark SQL",
        ],
        "code_tsdb": "SELECT add_compression_policy(\n  'metrics',\n  compress_after => '7 days'\n);",
        "code_lakets": "SELECT lakets.add_compression_policy(\n  'metrics', '7 days',\n  'device_id', 'time DESC'\n);\n-- Databricks job handles actual tiering",
        "insight": "LakeTS: cold data gets Delta ACID + lineage + ML/AI access. TimescaleDB: single-engine simplicity.",
    },
    {
        "title": "Retention & Lifecycle Policies",
        "subtitle": "Automated data expiry — single-tier vs hot/warm/cold lifecycle",
        "tsdb_title": "TimescaleDB: Single Drop Policy",
        "lakets_title": "LakeTS: Tiered Retention",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "add_retention_policy(t, drop_after => '30d')",
            "Background job drops expired chunks",
            "Binary: data exists or is gone",
            "No tiered lifecycle management",
        ],
        "lakets_items": [
            "add_retention_policy('t', '30 days') — basic",
            "add_tiered_retention_policy('t', '7d', '90d')",
            "Hot (0-7d) → Warm/Delta (7-90d) → Drop",
            "retention_job.py runs daily at 3 AM",
        ],
        "code_tsdb": "SELECT add_retention_policy(\n  'metrics',\n  drop_after => '30 days'\n);",
        "code_lakets": "SELECT lakets.add_tiered_retention_policy(\n  'metrics',\n  '7 days',   -- tier to Delta\n  '90 days'   -- drop from Delta\n);",
        "insight": "LakeTS innovation: tiered retention. RollUps survive raw data deletion — aggregation data is independent.",
    },
    {
        "title": "Shadow Sync: CDC for Lakebase",
        "subtitle": "Bridging Postgres partitions to Delta Lake via wal2delta",
        "tsdb_title": "TimescaleDB: Not Needed",
        "lakets_title": "LakeTS: Shadow Table Pattern",
        "tsdb_icon": "postgresql",
        "lakets_icon": "delta_lake",
        "tsdb_items": [
            "TimescaleDB is self-contained",
            "No need to bridge to external lakehouse",
            "S3 tiering built into Tiger Cloud",
            "Single-engine: all queries hit Postgres",
        ],
        "lakets_items": [
            "Lakehouse Sync can't CDC partitioned tables",
            "enable_sync() creates _shadow_<table>",
            "AFTER INSERT trigger copies to shadow table",
            "wal2delta reads shadow WAL → Delta Lake",
        ],
        "code_tsdb": "-- No sync needed in TimescaleDB\n-- All data stays in Postgres\n-- Cold data in S3 (Tiger Cloud)",
        "code_lakets": "SELECT lakets.enable_sync('metrics');\n-- Creates: _shadow_metrics\n-- Trigger: partition->parent->shadow\n-- wal2delta: shadow WAL -> Delta",
        "insight": "Shadow sync bridges Lakebase ↔ Delta Lake. 2x write amplification trade-off accepted for lakehouse benefits.",
    },
    {
        "title": "Last Value Cache (LakeTS Innovation)",
        "subtitle": "Sub-10ms latest-state queries via trigger-maintained cache",
        "tsdb_title": "TimescaleDB: No Built-In Cache",
        "lakets_title": "LakeTS: Trigger-Maintained LVC",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "No dedicated latest-value optimization",
            "DISTINCT ON (device) ORDER BY time DESC",
            "Full table scan or index scan required",
            "Latency grows with data volume",
        ],
        "lakets_items": [
            "enable_lvc('t', key_cols, value_cols)",
            "_lvc_<table> with keys as PRIMARY KEY",
            "AFTER INSERT trigger UPSERTs every write",
            "latest_values('t') — sub-10ms single lookup",
        ],
        "code_tsdb": "-- Full scan needed\nSELECT DISTINCT ON (device_id)\n  device_id, cpu, time\nFROM metrics\nORDER BY device_id, time DESC;",
        "code_lakets": "SELECT lakets.enable_lvc(\n  'metrics',\n  ARRAY['device_id'],\n  ARRAY['cpu', 'memory']\n);\nSELECT * FROM\n  lakets.latest_values('metrics');",
        "insight": "LakeTS-only feature. Critical for IoT dashboards showing current state of thousands of devices.",
    },
    {
        "title": "Multi-Metric Tables & Bulk Ingest",
        "subtitle": "InfluxDB-style tagged model + server-side batch functions",
        "tsdb_title": "TimescaleDB: Narrow Model Only",
        "lakets_title": "LakeTS: Tagged + Ingest APIs",
        "tsdb_icon": "postgresql",
        "lakets_icon": "databricks",
        "tsdb_items": [
            "Single-metric per column (wide table)",
            "No built-in tag/field distinction",
            "Standard COPY/INSERT for bulk load",
            "No native Prometheus ingest format",
        ],
        "lakets_items": [
            "create_metric_table(tags[], fields[], intv)",
            "InfluxDB-style: tags (TEXT) + fields (FLOAT8)",
            "ingest_batch('t', '[{...}]'::JSONB) server-side",
            "ingest_prometheus() for Prometheus format",
        ],
        "code_tsdb": "CREATE TABLE metrics (\n  time TIMESTAMPTZ NOT NULL,\n  host TEXT, region TEXT,\n  cpu FLOAT8, memory FLOAT8\n);\nSELECT create_hypertable(\n  'metrics', 'time');",
        "code_lakets": "SELECT lakets.create_metric_table(\n  'metrics',\n  ARRAY['host','region'],\n  ARRAY['cpu','memory'], '1 day'\n);\nSELECT lakets.ingest_batch('metrics',\n  '[{\"time\":\"...\",\"cpu\":72.5}]');",
        "insight": "LakeTS adds cardinality_check() to warn when tag cardinality exceeds thresholds (IoT anti-pattern).",
    },
    {
        "title": "Downsampling & Auto-Resolution",
        "subtitle": "Multi-resolution rollups — hierarchical caggs vs Delta pipelines",
        "tsdb_title": "TimescaleDB: Hierarchical CAGGs",
        "lakets_title": "LakeTS: Downsample Registry + Spark",
        "tsdb_icon": "postgresql",
        "lakets_icon": "spark",
        "tsdb_items": [
            "Continuous aggregate on top of another",
            "1min → 1hour → 1day cascading refresh",
            "All in Postgres, WAL-tracked",
            "Query the finest cagg you need",
        ],
        "lakets_items": [
            "create_downsample_pipeline(resolutions[])",
            "Registry on Lakebase, Spark execution",
            "Delta tables per resolution (Z-ORDER)",
            "query_auto_resolution() picks best for range",
        ],
        "code_tsdb": "CREATE MATERIALIZED VIEW hourly\nWITH (continuous) AS\nSELECT time_bucket('1h', time),\n  avg(cpu) FROM metrics\nGROUP BY 1;\n-- Then build daily on hourly",
        "code_lakets": "SELECT lakets.create_downsample_pipeline(\n  'rollups', 'metrics',\n  ARRAY['1 min','1 hour','1 day'],\n  ARRAY['30 days','1 year','100 yr'],\n  ARRAY['avg(cpu)'],ARRAY['host']);",
        "insight": "LakeTS advantage: Spark handles petabyte-scale rollups. TimescaleDB: fully integrated, no external job.",
    },
    {
        "title": "Alerting & Monitoring",
        "subtitle": "SQL-native observability — external tooling vs built-in functions",
        "tsdb_title": "TimescaleDB: External Only",
        "lakets_title": "LakeTS: SQL-Native + Prometheus",
        "tsdb_icon": "postgresql",
        "lakets_icon": "grafana",
        "tsdb_items": [
            "No built-in alerting functions",
            "Relies on Grafana Alerts / external tools",
            "timescaledb_information views for metadata",
            "Manual monitoring setup required",
        ],
        "lakets_items": [
            "alert_check(name, query, severity) — SQL alerts",
            "alert_deadman(name, tbl, key, timeout) — stale",
            "lakets_metrics() — Prometheus-compatible",
            "chunk_health(), query_stats() — built-in views",
        ],
        "code_tsdb": "-- External only: must configure\n-- Grafana alerts / Prometheus\n-- + AlertManager pipeline\n-- No SQL-level alert functions",
        "code_lakets": "SELECT * FROM lakets.alert_check(\n  'high_cpu',\n  $$SELECT host, max(cpu)\n    FROM metrics GROUP BY host\n    HAVING max(cpu) > 90$$,\n  'critical');",
        "insight": "LakeTS provides 8 Prometheus-compatible metrics via lakets_metrics() + pre-built Grafana dashboards.",
    },
]


def main():
    token = get_token()
    created_ids = []

    # 1. Section header slide
    print("Creating section header...")
    sec_id = add_section_slide("Feature Deep-Dives",
        "TimescaleDB Features → LakeTS Implementation", token)
    if sec_id:
        created_ids.append(sec_id)
        print(f"  Section: {sec_id}")
    else:
        print("  Section header failed, creating blank fallback...")
        sec_id = create_blank_slide(token)
        created_ids.append(sec_id)
        reqs = make_title_bar(sec_id, "Feature Deep-Dives",
            "TimescaleDB Features → LakeTS Implementation")
        batch_update(PRES_ID, reqs, token)
        print(f"  Blank section: {sec_id}")

    # 2. Feature slides
    for i, feat in enumerate(FEATURES):
        print(f"\n[{i+1}/{len(FEATURES)}] {feat['title']}...")
        sid = create_blank_slide(token)
        created_ids.append(sid)

        reqs = build_feature_slide(
            token, sid,
            title=feat["title"],
            subtitle=feat["subtitle"],
            tsdb_title=feat["tsdb_title"],
            lakets_title=feat["lakets_title"],
            tsdb_items=feat["tsdb_items"],
            lakets_items=feat["lakets_items"],
            code_tsdb=feat.get("code_tsdb"),
            code_lakets=feat.get("code_lakets"),
            insight=feat.get("insight"),
            tsdb_icon=feat.get("tsdb_icon"),
            lakets_icon=feat.get("lakets_icon"),
        )

        result = batch_update(PRES_ID, reqs, token)
        if "error" in result:
            print(f"  ERROR: {result['error'].get('message', '')[:200]}")
        else:
            print(f"  OK ({len(reqs)} elements)")
        time.sleep(0.5)

    # Save IDs
    with open("/tmp/feature_slide_ids.json", "w") as f:
        json.dump(created_ids, f, indent=2)

    print(f"\n{'='*50}")
    print(f"Created {len(created_ids)} slides (1 section + {len(FEATURES)} features)")
    for sid in created_ids:
        print(f"  {sid}")
    print("IDs saved to /tmp/feature_slide_ids.json")


if __name__ == "__main__":
    main()
