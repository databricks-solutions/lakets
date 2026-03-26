#!/usr/bin/env python3
"""Create the LakeTS Google Slides presentation using gslides_builder.py create-from-spec."""

import json
import subprocess
import os
import sys
import time

BUILDER = os.path.expanduser(
    "~/.claude/plugins/cache/fe-vibe/fe-google-tools/1.2.9/skills/google-slides/resources/gslides_builder.py"
)
AUTH = os.path.expanduser(
    "~/.claude/plugins/cache/fe-vibe/fe-google-tools/1.2.9/skills/google-auth/resources/google_auth.py"
)
QUOTA_PROJECT = "gcp-sandbox-field-eng"
DIAGRAMS_DIR = os.path.expanduser(
    "~/Documents/Claude Projects/Lakebase/timeseries/diagrams"
)

# Images already uploaded from the first run
UPLOADED_IMAGES = {
    "02_timescaledb_internals.png": "1JQMCfhb5rX7XUdVtrY5wR3zCdwn1XvCQ",
    "01_lakets_architecture.png": "1lG-N_QSVOCLXUPbEerxIoebw9aBDMuLT",
    "03_data_lifecycle_drawio.png": "1cw1WddgOVRrCZuZ3zZcsrUyvbcycq0t9",
    "04_lakets_vs_timescaledb.png": "1VRjp1y8iziYyFIxuOZilLYzVyKi_EBW_",
}


def get_token():
    """Get access token via google_auth.py."""
    r = subprocess.run(
        ["python3", AUTH, "token"], capture_output=True, text=True
    )
    token = r.stdout.strip()
    if not token or len(token) < 50:
        # Fallback to gcloud
        r2 = subprocess.run(
            ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
             "auth", "application-default", "print-access-token"],
            capture_output=True, text=True,
        )
        token = r2.stdout.strip()
    return token


def get_image_url(file_id):
    """Get a publicly accessible URL for a Drive file."""
    return f"https://drive.google.com/uc?id={file_id}&export=download"


def api_call(method, url, data=None, token=None):
    """Make an authenticated API call."""
    if token is None:
        token = get_token()
    cmd = ["curl", "-s"]
    if method == "POST":
        cmd += ["-X", "POST"]
    cmd += [
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-H", "Content-Type: application/json",
        url,
    ]
    if data:
        cmd += ["-d", json.dumps(data)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        print(f"API error: {r.stdout[:500]}")
        return {}


def batch_update(pres_id, requests, token=None):
    """Send batch update to Slides API."""
    url = f"https://slides.googleapis.com/v1/presentations/{pres_id}:batchUpdate"
    return api_call("POST", url, {"requests": requests}, token)


def add_image_to_slide(pres_id, slide_id, image_url, token):
    """Add an image to a title_only slide below the title."""
    print(f"  Adding image to {slide_id}...")
    requests = [{
        "createImage": {
            "objectId": f"{slide_id}_img",
            "url": image_url,
            "elementProperties": {
                "pageObjectId": slide_id,
                "size": {
                    "width": {"magnitude": 10800000, "unit": "EMU"},
                    "height": {"magnitude": 5200000, "unit": "EMU"},
                },
                "transform": {
                    "scaleX": 1,
                    "scaleY": 1,
                    "translateX": 700000,
                    "translateY": 1400000,
                    "unit": "EMU",
                },
            },
        }
    }]
    result = batch_update(pres_id, requests, token)
    if "error" in result:
        print(f"    Image error: {result['error'].get('message', '')[:200]}")
    return result


def main():
    print("=" * 60)
    print("LakeTS Google Slides - v2 (using gslides_builder.py)")
    print("=" * 60)

    # Build the spec - 24 slides
    spec = [
        # 1. Title
        {
            "layout": "title",
            "title": "LakeTS: Time Series for\nDatabricks Lakebase",
            "subtitle": "Taran Grover  |  March 2026",
        },
        # 2. The Problem
        {
            "layout": "content_basic",
            "title": "The Problem",
            "body": (
                "Time-series is the fastest-growing database workload\n"
                "IoT, observability, and real-time analytics need time-partitioned storage\n"
                "Lakebase (managed PostgreSQL) has no native time-series support\n"
                "TimescaleDB requires a custom C extension \u2014 cannot install on managed PG\n"
                "LakeTS fills this gap: TimescaleDB capabilities via pure SQL, zero extensions"
            ),
            "bullets": True,
        },
        # 3. Section: What is TimescaleDB?
        {
            "layout": "section_break_1",
            "title": "What is TimescaleDB (TigerData)?",
        },
        # 4. TimescaleDB Overview
        {
            "layout": "content_basic",
            "title": "TimescaleDB Overview",
            "body": (
                "C-native PostgreSQL extension \u2014 hooks into PG planner at C level\n"
                "Hypertables: auto-partition tables by time into chunks\n"
                "Columnar compression: up to 98% storage reduction\n"
                "Continuous aggregates: WAL-tracked incremental refresh\n"
                "Hyperfunctions: time_bucket, first/last, delta/rate, histogram\n"
                "Data tiering: bottomless S3 storage (Tiger Cloud)\n"
                "Rebranded to TigerData (June 2025) \u2014 2,000+ customers, $180M raised"
            ),
            "bullets": True,
        },
        # 5. TimescaleDB Architecture (diagram - title_only + image added later)
        {
            "layout": "title_only",
            "title": "TimescaleDB Architecture",
        },
        # 6. TimescaleDB Core Features (3-col)
        {
            "layout": "content_3col",
            "title": "TimescaleDB Core Features",
            "columns": [
                "Hypertables",
                "Auto-partition by time\nChunk exclusion in planner\nTransparent to SQL\nEach chunk = real PG table",
                "Columnar Compression",
                "98% compression ratio\nBatch of 1000 rows\nVectorized query engine\nTOAST page storage",
                "Continuous Aggregates",
                "Incremental WAL refresh\nReal-time UNION view\nLow maintenance\nMaterialized + fresh data",
            ],
        },
        # 7. pgai & pgvectorscale
        {
            "layout": "content_basic",
            "title": "TimescaleDB: pgai & pgvectorscale",
            "body": (
                "pgai Vectorizer: generate AI embeddings directly from SQL\n"
                "Supports OpenAI, Ollama, Cohere, Mistral, HuggingFace via LiteLLM\n"
                "pgvectorscale: high-performance vector search extension\n"
                "Enables RAG, semantic search, and AI agent workloads alongside time-series\n"
                "Positions TigerData for the agentic era \u2014 SQL-native AI"
            ),
            "bullets": True,
        },
        # 8. Section: LakeTS
        {
            "layout": "section_break_2",
            "title": "LakeTS: The Solution",
        },
        # 9. Design Philosophy
        {
            "layout": "content_basic",
            "title": "LakeTS Design Philosophy",
            "body": (
                "Pure SQL \u2014 no C extension required, works on any Lakebase instance\n"
                "Native PG RANGE partitioning \u2014 ChronoTables replace hypertables\n"
                "Two-tier architecture \u2014 hot data in Lakebase, cold data in Delta Lake\n"
                "Databricks Workflows \u2014 4 automated jobs manage the full data lifecycle\n"
                "Shadow table CDC \u2014 workaround for Lakehouse Sync on partitioned tables\n"
                "56+ SQL functions \u2014 complete TimescaleDB API parity in PL/pgSQL"
            ),
            "bullets": True,
        },
        # 10. LakeTS Architecture (diagram - title_only + image added later)
        {
            "layout": "title_only",
            "title": "LakeTS Architecture Overview",
        },
        # 11. Hot vs Cold (2-col)
        {
            "layout": "content_2col",
            "title": "Hot Tier vs Cold Tier",
            "columns": [
                "Hot: Lakebase (0-7 days)",
                "ChronoTables (PG partitions)\nTime-series functions\nContinuous aggregates\nLast Value Cache (<10ms)\nAlert rules\nPrometheus monitoring",
                "Cold: Delta Lake (7-90+ days)",
                "Tiered compressed chunks\nDownsampled rollups (1m/1h/1d)\nPhoton analytics\nMLflow + Feature Store\nUnity Catalog governance\nTime travel + Z-ORDER",
            ],
        },
        # 12. Core Modules (3-col)
        {
            "layout": "content_3col",
            "title": "Core Modules",
            "columns": [
                "ChronoTables",
                "Native PG RANGE partitioning\nAuto-create future partitions\ncreate_hypertable()\nshow_chunks() / drop_chunks()",
                "Time Series Functions",
                "time_bucket() \u2014 round to interval\nfirst() / last() by time\ngapfill + interpolate\ndelta() / rate() counters",
                "Continuous Aggregates",
                "Materialized view + UNION\nRefresh every 15 minutes\nReal-time view pattern\nWatermark tracking",
            ],
        },
        # 13. Advanced Modules (3-col)
        {
            "layout": "content_3col",
            "title": "Advanced Modules",
            "columns": [
                "Last Value Cache",
                "Trigger-maintained cache\nSub-10ms latest-state\nUPSERT on every INSERT\nOpt-in per table",
                "Shadow Sync (CDC)",
                "Unpartitioned shadow table\nTrigger copies all writes\nREPLICA IDENTITY FULL\nwal2delta compatible",
                "Alert Rules",
                "SQL-native threshold alerts\nDeadman detection\nalert_check() query-based\nReturns JSONB alert data",
            ],
        },
        # 14. Section: Data Lifecycle
        {
            "layout": "section_break_1",
            "title": "Data Lifecycle",
        },
        # 15. Data Lifecycle Flow (diagram - title_only + image added later)
        {
            "layout": "title_only",
            "title": "Data Lifecycle Flow",
        },
        # 16. Lifecycle Automation
        {
            "layout": "content_basic",
            "title": "Lifecycle Automation",
            "body": (
                "Partition Manager \u2014 pre-creates future partitions every 6 hours\n"
                "Compression Job \u2014 tiers old chunks to Delta Lake daily at 2 AM UTC\n"
                "Retention Job \u2014 drops expired data daily at 3 AM UTC (instant per partition)\n"
                "CAGG Refresh \u2014 updates materialized views every 15 minutes\n"
                "All policy-driven from _policy_registry metadata table\n"
                "Deployed via Databricks Asset Bundles (1-click setup)"
            ),
            "bullets": True,
        },
        # 17. Section: Comparison
        {
            "layout": "section_break_2",
            "title": "LakeTS vs TimescaleDB",
        },
        # 18. Architecture Comparison (diagram - title_only + image added later)
        {
            "layout": "title_only",
            "title": "Architecture Comparison",
        },
        # 19. Comparison Scorecard (table)
        {
            "layout": "title_only",
            "title": "Comparison Scorecard",
            "table": {
                "data": [
                    ["Feature", "TimescaleDB", "LakeTS", "Winner"],
                    ["Raw Performance", "C-native engine", "PL/pgSQL (~5-10% slower)", "TimescaleDB"],
                    ["Cold Storage", "S3 decompress-on-read", "Delta Lake (ACID, Photon)", "LakeTS"],
                    ["Installation", "Custom C extension", "Pure SQL, zero install", "LakeTS"],
                    ["ML/AI Integration", "pgai + pgvectorscale", "MLflow, Feature Store, Spark", "LakeTS"],
                    ["CAGG Refresh", "Incremental (WAL)", "Full matview refresh", "TimescaleDB"],
                    ["Cost Model", "Per-node (Tiger Cloud)", "Serverless, scale-to-zero", "LakeTS"],
                    ["Community", "2000+ customers", "Emerging (Databricks)", "TimescaleDB"],
                ],
                "y": 1.8,
                "width": 11.5,
                "height": 4.5,
            },
        },
        # 20. Benchmark Results (table)
        {
            "layout": "title_only",
            "title": "Benchmark Results (CU_1 Lakebase)",
            "table": {
                "data": [
                    ["Benchmark", "LakeTS", "TimescaleDB", "Notes"],
                    ["Ingest (rows/sec)", "548,000", "~500,000", "Competitive"],
                    ["Simple Query", "44ms", "~5ms", "PL/pgSQL overhead"],
                    ["Hourly Aggregation", "157ms", "~50ms", "Expected on CU_1"],
                    ["Gap-Fill (5-day)", "11ms", "~10ms", "Near parity"],
                    ["CAGG Refresh", "59ms", "~200ms", "LakeTS faster"],
                ],
                "y": 1.8,
                "width": 11.5,
                "height": 3.8,
            },
        },
        # 21. By the Numbers (3-col)
        {
            "layout": "content_3col",
            "title": "LakeTS by the Numbers",
            "columns": [
                "SQL Toolkit",
                "56+ SQL functions\n14 SQL modules\n2,400+ lines of SQL\nComplete API parity",
                "Testing",
                "57+ tests passing\n685 lines of tests\n12 test suites\nLive on PG 16.12",
                "Automation",
                "4 Databricks Workflows\n9 Grafana panels\n7 documentation files\n1-click Asset Bundle deploy",
            ],
        },
        # 22. Getting Started
        {
            "layout": "content_basic",
            "title": "Getting Started",
            "body": (
                "Run 99_install.sql on any Lakebase instance (creates lakets schema)\n"
                "Call create_hypertable() on your existing table with a time column\n"
                "Add compression and retention policies via add_compression_policy()\n"
                "Deploy Databricks Workflows via Asset Bundle (databricks.yml)\n"
                "Enable Lakehouse Sync for cold tier via enable_sync()\n"
                "Connect Grafana to Monitoring endpoint for operational dashboards"
            ),
            "bullets": True,
        },
        # 23. Roadmap
        {
            "layout": "content_basic",
            "title": "Roadmap & Next Steps",
            "body": (
                "V2 Complete: multi-metric tables, LVC, downsampling, alerts, bulk ingest\n"
                "Next: anomaly detection (SQL-native Z-score + IQR on hot data)\n"
                "Next: forecasting (Spark ML models on cold tier, serve via Lakebase)\n"
                "Next: multi-node partitioning (shard across Lakebase instances)\n"
                "Next: pg_cron integration (replace external workflow scheduler)\n"
                "Goal: open-source LakeTS as a Databricks Labs project"
            ),
            "bullets": True,
        },
        # 24. Closing
        {
            "layout": "closing",
        },
    ]

    # Image slides (0-indexed positions in spec) -> Drive file IDs
    image_slides = {
        4: "02_timescaledb_internals.png",   # slide 5: TimescaleDB Architecture
        9: "01_lakets_architecture.png",      # slide 10: LakeTS Architecture
        14: "03_data_lifecycle_drawio.png",   # slide 15: Data Lifecycle
        17: "04_lakets_vs_timescaledb.png",   # slide 18: Comparison
    }

    # Write spec to temp file (too large for CLI arg)
    spec_file = "/tmp/lakets_slides_spec.json"
    with open(spec_file, "w") as f:
        json.dump(spec, f)

    # Step 1: Create presentation from spec
    print("\n[Step 1] Creating presentation with 24 slides...")
    print("  (This takes 5-8 minutes for 24 slides - please wait)")

    # Read spec from file and pass as argument
    spec_json = json.dumps(spec)
    result = subprocess.run(
        [
            "python3", BUILDER,
            "create-from-spec",
            "--title", "LakeTS: Time Series for Databricks Lakebase",
            "--theme", "light",
            "--spec", spec_json,
        ],
        capture_output=True, text=True, timeout=600,
    )

    print(f"  stdout: {result.stdout[:500]}")
    if result.stderr:
        print(f"  stderr: {result.stderr[:500]}")

    try:
        output = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"Failed to parse output. Full stdout:\n{result.stdout}")
        sys.exit(1)

    pres_id = output.get("presentationId")
    if not pres_id:
        print(f"No presentation ID returned: {output}")
        sys.exit(1)

    pres_url = output.get("url", f"https://docs.google.com/presentation/d/{pres_id}/edit")
    print(f"\n  Presentation created: {pres_url}")

    # Get slide IDs
    slide_ids = output.get("slideIds", [])
    print(f"  Created {len(slide_ids)} slides")

    # Step 2: Add images to diagram slides
    print("\n[Step 2] Adding diagram images to slides...")
    token = get_token()

    for spec_idx, img_name in image_slides.items():
        if spec_idx < len(slide_ids):
            slide_id = slide_ids[spec_idx]
            file_id = UPLOADED_IMAGES.get(img_name)
            if file_id:
                image_url = get_image_url(file_id)
                add_image_to_slide(pres_id, slide_id, image_url, token)
            else:
                print(f"  WARNING: No uploaded file for {img_name}")
        else:
            print(f"  WARNING: Slide index {spec_idx} not found")

    # Step 3: Validate
    print("\n[Step 3] Validating presentation...")
    val_result = subprocess.run(
        ["python3", BUILDER, "validate", "--pres-id", pres_id],
        capture_output=True, text=True, timeout=60,
    )
    print(f"  {val_result.stdout[:1000]}")

    print("\n" + "=" * 60)
    print(f"DONE! Presentation URL:")
    print(f"  {pres_url}")
    print("=" * 60)


if __name__ == "__main__":
    main()
