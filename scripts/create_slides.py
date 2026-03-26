#!/usr/bin/env python3
"""Create the LakeTS Google Slides presentation from the Databricks template."""

import json
import subprocess
import time
import sys
import os

PRES_ID = "1p10JgmUUSNlci0EpvPdK9-14xzCRer5B4clhP0WtGQw"
QUOTA_PROJECT = "gcp-sandbox-field-eng"

# Layout IDs from the template
LAYOUTS = {
    "title_light_4": "g32c3cd6d0e3_1_108",
    "title_light_1": "g324ba092b07_3_198",
    "content_basic": "g324ba092b07_3_45",
    "content_basic_white": "g324ba092b07_3_215",
    "two_column": "g324ba092b07_3_50",
    "three_column": "g324ba092b07_3_66",
    "three_column_cards": "g324ba092b07_3_92",
    "card_right": "g324ba092b07_3_105",
    "card_large": "g324ba092b07_3_119",
    "section_break_2": "g32fee89b7b9_0_39",
    "section_break_3": "g32fee89b7b9_0_49",
    "section_break_5": "g32fee89b7b9_0_74",
    "section_break_6": "g3344513dabd_0_5",
    "title_only": "p6",
    "blank": "p12",
    "closing_dark": "g324ba092b07_3_379",
    "closing_light": "g324ba092b07_3_233",
}

# Slide definitions
SLIDES = [
    # --- OPENING ---
    {
        "id": "slide_01_title",
        "layout": "title_light_4",
        "placeholders": {
            "CENTERED_TITLE": "LakeTS: Time Series for\nDatabricks Lakebase",
            "SUBTITLE_0": "Taran Grover",
            "SUBTITLE_1": "March 2026",
        },
    },
    {
        "id": "slide_02_problem",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "The Problem",
            "BODY_0": (
                "Time-series is the fastest-growing database workload\n"
                "IoT, observability, and real-time analytics all need time-partitioned storage\n"
                "Lakebase (managed PostgreSQL) has no native time-series support\n"
                "TimescaleDB requires a custom C extension — cannot install on managed PG\n"
                "LakeTS fills this gap: TimescaleDB capabilities via pure SQL, zero extensions"
            ),
        },
        "bullets": ["BODY_0"],
    },

    # --- WHAT IS TIMESCALEDB ---
    {
        "id": "slide_03_section_ts",
        "layout": "section_break_2",
        "placeholders": {
            "TITLE": "What is TimescaleDB\n(TigerData)?",
            "SUBTITLE": "The market-leading PostgreSQL time-series extension",
        },
    },
    {
        "id": "slide_04_ts_overview",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "TimescaleDB Overview",
            "BODY_0": (
                "C-native PostgreSQL extension — hooks into PG planner at C level\n"
                "Hypertables: auto-partition tables by time into chunks\n"
                "Columnar compression: up to 98% storage reduction\n"
                "Continuous aggregates: WAL-tracked incremental refresh\n"
                "Hyperfunctions: time_bucket, first/last, delta/rate, histogram\n"
                "Data tiering: bottomless S3 storage (Tiger Cloud)\n"
                "Company rebranded to TigerData (June 2025) — 2,000+ customers, $180M raised"
            ),
        },
        "bullets": ["BODY_0"],
    },
    {
        "id": "slide_05_ts_arch",
        "layout": "title_only",
        "placeholders": {"TITLE": "TimescaleDB Architecture"},
        "image": "02_timescaledb_internals.png",
    },
    {
        "id": "slide_06_ts_features",
        "layout": "three_column",
        "placeholders": {
            "TITLE": "TimescaleDB Core Features",
            "SUBTITLE_0": "Hypertables",
            "BODY_0": "Auto-partition by time\nChunk exclusion in planner\nTransparent to SQL\nEach chunk = real PG table",
            "SUBTITLE_1": "Columnar Compression",
            "BODY_1": "98% compression ratio\nBatch of 1000 rows\nVectorized query engine\nTOAST page storage",
            "SUBTITLE_2": "Continuous Aggregates",
            "BODY_2": "Incremental WAL refresh\nReal-time UNION view\nLow maintenance\nMaterialized + fresh data",
        },
    },
    {
        "id": "slide_07_ts_ai",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "TimescaleDB: pgai & pgvectorscale",
            "BODY_0": (
                "pgai Vectorizer: generate AI embeddings directly from SQL\n"
                "Supports OpenAI, Ollama, Cohere, Mistral, HuggingFace via LiteLLM\n"
                "pgvectorscale: high-performance vector search extension\n"
                "Enables RAG, semantic search, and AI agent workloads alongside time-series\n"
                "Positions TigerData for the agentic era — SQL-native AI"
            ),
        },
        "bullets": ["BODY_0"],
    },

    # --- LAKETS ARCHITECTURE ---
    {
        "id": "slide_08_section_lakets",
        "layout": "section_break_3",
        "placeholders": {
            "TITLE": "LakeTS: The Solution",
            "SUBTITLE": "TimescaleDB capabilities on Lakebase — pure SQL, zero extensions",
        },
    },
    {
        "id": "slide_09_philosophy",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "LakeTS Design Philosophy",
            "BODY_0": (
                "Pure SQL — no C extension required, works on any Lakebase instance\n"
                "Native PG RANGE partitioning — ChronoTables replace hypertables\n"
                "Two-tier architecture — hot data in Lakebase, cold data in Delta Lake\n"
                "Databricks Workflows — 4 automated jobs manage the full data lifecycle\n"
                "Shadow table CDC — workaround for Lakehouse Sync on partitioned tables\n"
                "56+ SQL functions — complete TimescaleDB API parity in PL/pgSQL"
            ),
        },
        "bullets": ["BODY_0"],
    },
    {
        "id": "slide_10_lakets_arch",
        "layout": "title_only",
        "placeholders": {"TITLE": "LakeTS Architecture Overview"},
        "image": "01_lakets_architecture.png",
    },
    {
        "id": "slide_11_hot_cold",
        "layout": "two_column",
        "placeholders": {
            "TITLE": "Hot Tier vs Cold Tier",
            "SUBTITLE_0": "Hot: Lakebase (0-7 days)",
            "BODY_0": "ChronoTables (PG partitions)\nTime-series functions\nContinuous aggregates\nLast Value Cache (<10ms)\nAlert rules\nPrometheus monitoring",
            "SUBTITLE_1": "Cold: Delta Lake (7-90+ days)",
            "BODY_1": "Tiered compressed chunks\nDownsampled rollups (1m/1h/1d)\nPhoton-accelerated analytics\nMLflow + Feature Store\nUnity Catalog governance\nTime travel + Z-ORDER",
        },
    },
    {
        "id": "slide_12_core_modules",
        "layout": "three_column_cards",
        "placeholders": {
            "TITLE": "Core Modules",
            "SUBTITLE_0": "ChronoTables",
            "BODY_0": "Native PG RANGE partitioning\nAuto-create future partitions\ncreate_hypertable()\nshow_chunks() / drop_chunks()\nNo extension needed",
            "SUBTITLE_1": "Time Series Functions",
            "BODY_1": "time_bucket() — round to interval\nfirst() / last() — by time\ngapfill + locf + interpolate\ndelta() / rate() — counters\nhistogram() — bucketing",
            "SUBTITLE_2": "Continuous Aggregates",
            "BODY_2": "Materialized view + UNION\nRefresh every 15 minutes\nReal-time view pattern\nNon-blocking refresh\nWatermark tracking",
        },
    },
    {
        "id": "slide_13_advanced",
        "layout": "three_column_cards",
        "placeholders": {
            "TITLE": "Advanced Modules",
            "SUBTITLE_0": "Last Value Cache",
            "BODY_0": "Trigger-maintained cache\nSub-10ms latest-state queries\nUPSERT on every INSERT\n10-15% write overhead\nOpt-in per table",
            "SUBTITLE_1": "Shadow Sync (CDC)",
            "BODY_1": "Unpartitioned shadow table\nTrigger copies all writes\nREPLICA IDENTITY FULL\nwal2delta CDC compatible\nResolves parent via pg_inherits",
            "SUBTITLE_2": "Alert Rules",
            "BODY_2": "SQL-native threshold alerts\nDeadman detection (stale)\nalert_check() — run query\nalert_deadman() — no data\nReturns JSONB alert data",
        },
    },

    # --- DATA LIFECYCLE ---
    {
        "id": "slide_14_section_lifecycle",
        "layout": "section_break_6",
        "placeholders": {
            "TITLE": "Data Lifecycle",
            "SUBTITLE": "From ingest to archive — automated hot/warm/cold tiering",
        },
    },
    {
        "id": "slide_15_lifecycle_diagram",
        "layout": "title_only",
        "placeholders": {"TITLE": "Data Lifecycle Flow"},
        "image": "03_data_lifecycle_drawio.png",
    },
    {
        "id": "slide_16_automation",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "Lifecycle Automation",
            "BODY_0": (
                "Partition Manager — pre-creates future partitions every 6 hours\n"
                "Compression Job — tiers old chunks to Delta Lake daily at 2 AM UTC\n"
                "Retention Job — drops expired data daily at 3 AM UTC (instant per partition)\n"
                "CAGG Refresh — updates materialized views every 15 minutes\n"
                "All policy-driven from _policy_registry metadata table\n"
                "Deployed via Databricks Asset Bundles (1-click setup)"
            ),
        },
        "bullets": ["BODY_0"],
    },

    # --- COMPARISON ---
    {
        "id": "slide_17_section_compare",
        "layout": "section_break_5",
        "placeholders": {
            "TITLE": "LakeTS vs TimescaleDB",
            "SUBTITLE": "Feature-by-feature comparison",
        },
    },
    {
        "id": "slide_18_compare_diagram",
        "layout": "title_only",
        "placeholders": {"TITLE": "Architecture Comparison"},
        "image": "04_lakets_vs_timescaledb.png",
    },
    {
        "id": "slide_19_scorecard",
        "layout": "title_only",
        "placeholders": {"TITLE": "Comparison Scorecard"},
        "table": {
            "data": [
                ["Feature", "TimescaleDB", "LakeTS", "Winner"],
                ["Raw Performance", "C-native engine", "PL/pgSQL (~5-10% slower)", "TimescaleDB"],
                ["Cold Storage", "S3 decompress-on-read", "Delta Lake (ACID, Photon)", "LakeTS"],
                ["Installation", "Custom C extension", "Pure SQL, zero install", "LakeTS"],
                ["ML/AI Integration", "pgai + pgvectorscale", "MLflow, Feature Store, Spark", "LakeTS"],
                ["CAGG Refresh", "Incremental (WAL-tracked)", "Full matview refresh", "TimescaleDB"],
                ["Cost Model", "Per-node (Tiger Cloud)", "Serverless, scale-to-zero", "LakeTS"],
                ["Community", "2000+ customers, mature", "Emerging (Databricks)", "TimescaleDB"],
            ],
            "x": 0.5, "y": 1.5, "width": 11.5, "height": 4.5,
        },
    },

    # --- BENCHMARKS ---
    {
        "id": "slide_20_benchmarks",
        "layout": "title_only",
        "placeholders": {"TITLE": "Benchmark Results (CU_1 Lakebase)"},
        "table": {
            "data": [
                ["Benchmark", "LakeTS", "TimescaleDB", "Notes"],
                ["Ingest (rows/sec)", "548,000", "~500,000", "Competitive"],
                ["Simple Query", "44ms", "~5ms", "PL/pgSQL overhead"],
                ["Hourly Aggregation", "157ms", "~50ms", "Expected on CU_1"],
                ["Gap-Fill (5-day)", "11ms", "~10ms", "Near parity"],
                ["CAGG Refresh", "59ms", "~200ms", "LakeTS faster"],
            ],
            "x": 0.5, "y": 1.5, "width": 11.5, "height": 3.5,
        },
    },
    {
        "id": "slide_21_numbers",
        "layout": "three_column",
        "placeholders": {
            "TITLE": "LakeTS by the Numbers",
            "SUBTITLE_0": "SQL Toolkit",
            "BODY_0": "56+ SQL functions\n14 SQL modules\n2,400+ lines of SQL\nComplete API parity",
            "SUBTITLE_1": "Testing",
            "BODY_1": "57+ tests passing\n685 lines of tests\n12 test suites\nLive on PG 16.12",
            "SUBTITLE_2": "Automation",
            "BODY_2": "4 Databricks Workflows\n9 Grafana panels\n7 documentation files\n1-click Asset Bundle deploy",
        },
    },

    # --- GETTING STARTED & NEXT STEPS ---
    {
        "id": "slide_22_getting_started",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "Getting Started",
            "BODY_0": (
                "Run 99_install.sql on any Lakebase instance (creates lakets schema)\n"
                "Call create_hypertable() on your existing table with a time column\n"
                "Add compression and retention policies via add_compression_policy()\n"
                "Deploy Databricks Workflows via Asset Bundle (databricks.yml)\n"
                "Enable Lakehouse Sync for cold tier via enable_sync()\n"
                "Connect Grafana to Monitoring endpoint for operational dashboards"
            ),
        },
        "bullets": ["BODY_0"],
    },
    {
        "id": "slide_23_roadmap",
        "layout": "content_basic",
        "placeholders": {
            "TITLE": "Roadmap & Next Steps",
            "BODY_0": (
                "V2 Complete: multi-metric tables, LVC, downsampling, alerts, bulk ingest\n"
                "Next: anomaly detection (SQL-native Z-score + IQR on hot data)\n"
                "Next: forecasting (Spark ML models on cold tier, serve via Lakebase)\n"
                "Next: multi-node partitioning (shard across Lakebase instances)\n"
                "Next: pg_cron integration (replace external workflow scheduler)\n"
                "Goal: open-source LakeTS as a Databricks Labs project"
            ),
        },
        "bullets": ["BODY_0"],
    },
    {
        "id": "slide_24_closing",
        "layout": "closing_dark",
        "placeholders": {},
    },
]


def get_token():
    """Get gcloud access token."""
    result = subprocess.run(
        ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud", "auth", "application-default", "print-access-token"],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def api_call(method, url, data=None, token=None):
    """Make an authenticated API call."""
    if token is None:
        token = get_token()
    headers = [
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-H", "Content-Type: application/json",
    ]
    cmd = ["curl", "-s"]
    if method == "POST":
        cmd += ["-X", "POST"]
    cmd += headers
    cmd.append(url)
    if data:
        cmd += ["-d", json.dumps(data)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"API error: {result.stdout[:500]}")
        return {}


def batch_update(requests, token=None):
    """Send batch update to Slides API."""
    url = f"https://slides.googleapis.com/v1/presentations/{PRES_ID}:batchUpdate"
    return api_call("POST", url, {"requests": requests}, token)


def delete_sample_slides(token):
    """Delete all sample slides from the copied template."""
    # Get current slides
    pres = api_call("GET", f"https://slides.googleapis.com/v1/presentations/{PRES_ID}", token=token)
    slides = pres.get("slides", [])
    if not slides:
        print("No slides to delete")
        return

    slide_ids = [s["objectId"] for s in slides]
    print(f"Deleting {len(slide_ids)} sample slides...")

    # Need to keep at least 1 slide, so first create a blank slide
    batch_update([{"createSlide": {"objectId": "temp_blank", "slideLayoutReference": {"layoutId": "p12"}}}], token)

    # Now delete all original slides
    requests = [{"deleteObject": {"objectId": sid}} for sid in slide_ids]
    batch_update(requests, token)
    print("Sample slides deleted.")


def get_placeholders(slide_id, token):
    """Get placeholder elements from a slide."""
    pres = api_call("GET", f"https://slides.googleapis.com/v1/presentations/{PRES_ID}/pages/{slide_id}", token=token)
    placeholders = {}
    for elem in pres.get("pageElements", []):
        shape = elem.get("shape", {})
        ph = shape.get("placeholder", {})
        if ph:
            ph_type = ph.get("type", "")
            ph_index = ph.get("index", 0)
            key = f"{ph_type}_{ph_index}" if ph_index > 0 else ph_type
            placeholders[key] = {
                "objectId": elem["objectId"],
                "type": ph_type,
                "index": ph_index,
                "transform": elem.get("transform", {}),
                "size": elem.get("size", {}),
            }
    return placeholders


def set_placeholder_text(object_id, text, token):
    """Set text in a placeholder."""
    requests = [
        {"deleteText": {"objectId": object_id, "textRange": {"type": "ALL"}}},
        {"insertText": {"objectId": object_id, "text": text, "insertionIndex": 0}},
    ]
    return batch_update(requests, token)


def add_bullets(object_id, token):
    """Apply bullet formatting."""
    requests = [
        {
            "createParagraphBullets": {
                "objectId": object_id,
                "textRange": {"type": "ALL"},
                "bulletPreset": "BULLET_DISC_CIRCLE_SQUARE",
            }
        }
    ]
    return batch_update(requests, token)


def create_slide(slide_def, token):
    """Create a slide from definition."""
    layout_id = LAYOUTS[slide_def["layout"]]
    slide_id = slide_def["id"]

    print(f"  Creating slide: {slide_id} ({slide_def['layout']})")

    # Create the slide
    result = batch_update([{
        "createSlide": {
            "objectId": slide_id,
            "slideLayoutReference": {"layoutId": layout_id},
        }
    }], token)

    if "error" in result:
        print(f"    ERROR creating slide: {result['error']}")
        return

    time.sleep(0.5)

    # Get placeholders
    phs = get_placeholders(slide_id, token)

    # Set placeholder text
    for ph_key, text in slide_def.get("placeholders", {}).items():
        # Map our keys to actual placeholder IDs
        matched = False

        if ph_key == "CENTERED_TITLE":
            for k, v in phs.items():
                if v["type"] == "CENTERED_TITLE":
                    set_placeholder_text(v["objectId"], text, token)
                    matched = True
                    break

        elif ph_key == "TITLE":
            for k, v in phs.items():
                if v["type"] == "TITLE":
                    set_placeholder_text(v["objectId"], text, token)
                    matched = True
                    break

        elif ph_key.startswith("SUBTITLE_"):
            idx = int(ph_key.split("_")[1])
            for k, v in phs.items():
                if v["type"] == "SUBTITLE" and v["index"] == idx:
                    set_placeholder_text(v["objectId"], text, token)
                    matched = True
                    break

        elif ph_key == "SUBTITLE":
            for k, v in phs.items():
                if v["type"] == "SUBTITLE":
                    set_placeholder_text(v["objectId"], text, token)
                    matched = True
                    break

        elif ph_key.startswith("BODY_"):
            idx = int(ph_key.split("_")[1])
            # Find BODY placeholders sorted by spatial position
            body_phs = sorted(
                [(k, v) for k, v in phs.items() if v["type"] == "BODY"],
                key=lambda x: (
                    x[1].get("transform", {}).get("translateY", 0),
                    x[1].get("transform", {}).get("translateX", 0),
                ),
            )
            if idx < len(body_phs):
                set_placeholder_text(body_phs[idx][1]["objectId"], text, token)
                matched = True

        if not matched:
            print(f"    WARNING: Could not find placeholder {ph_key}")

    # Apply bullets
    for bullet_key in slide_def.get("bullets", []):
        idx = int(bullet_key.split("_")[1])
        body_phs = sorted(
            [(k, v) for k, v in phs.items() if v["type"] == "BODY"],
            key=lambda x: (
                x[1].get("transform", {}).get("translateY", 0),
                x[1].get("transform", {}).get("translateX", 0),
            ),
        )
        if idx < len(body_phs):
            add_bullets(body_phs[idx][1]["objectId"], token)


def add_image_to_slide(slide_id, image_url, token):
    """Add an image to a slide below the title."""
    print(f"  Adding image to {slide_id}")
    # Position: below title, centered, large
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
    return batch_update(requests, token)


def add_table_to_slide(slide_id, table_def, token):
    """Add a table to a slide."""
    data = table_def["data"]
    rows = len(data)
    cols = len(data[0])
    x = table_def.get("x", 0.5)
    y = table_def.get("y", 1.5)
    w = table_def.get("width", 11.0)
    h = table_def.get("height", 4.0)

    table_id = f"{slide_id}_table"
    print(f"  Adding {rows}x{cols} table to {slide_id}")

    # Create table
    requests = [{
        "createTable": {
            "objectId": table_id,
            "rows": rows,
            "columns": cols,
            "elementProperties": {
                "pageObjectId": slide_id,
                "size": {
                    "width": {"magnitude": int(w * 914400), "unit": "EMU"},
                    "height": {"magnitude": int(h * 914400), "unit": "EMU"},
                },
                "transform": {
                    "scaleX": 1, "scaleY": 1,
                    "translateX": int(x * 914400),
                    "translateY": int(y * 914400),
                    "unit": "EMU",
                },
            },
        }
    }]
    batch_update(requests, token)
    time.sleep(0.5)

    # Insert cell text
    cell_requests = []
    for r in range(rows):
        for c in range(cols):
            cell_requests.append({
                "insertText": {
                    "objectId": table_id,
                    "cellLocation": {"rowIndex": r, "columnIndex": c},
                    "text": data[r][c],
                    "insertionIndex": 0,
                }
            })
    batch_update(cell_requests, token)

    # Style header row
    header_requests = [{
        "updateTableCellProperties": {
            "objectId": table_id,
            "tableRange": {
                "location": {"rowIndex": 0, "columnIndex": 0},
                "rowSpan": 1, "columnSpan": cols,
            },
            "tableCellProperties": {
                "tableCellBackgroundFill": {
                    "solidFill": {
                        "color": {"rgbColor": {"red": 0.106, "green": 0.188, "blue": 0.216}},
                    }
                }
            },
            "fields": "tableCellBackgroundFill",
        }
    }]
    # Style header text to white
    for c in range(cols):
        header_requests.append({
            "updateTextStyle": {
                "objectId": table_id,
                "cellLocation": {"rowIndex": 0, "columnIndex": c},
                "textRange": {"type": "ALL"},
                "style": {
                    "bold": True,
                    "fontSize": {"magnitude": 12, "unit": "PT"},
                    "foregroundColor": {
                        "opaqueColor": {"rgbColor": {"red": 1.0, "green": 1.0, "blue": 1.0}},
                    },
                },
                "fields": "bold,fontSize,foregroundColor",
            }
        })
    # Style data rows
    for r in range(1, rows):
        for c in range(cols):
            header_requests.append({
                "updateTextStyle": {
                    "objectId": table_id,
                    "cellLocation": {"rowIndex": r, "columnIndex": c},
                    "textRange": {"type": "ALL"},
                    "style": {
                        "fontSize": {"magnitude": 11, "unit": "PT"},
                        "foregroundColor": {
                            "opaqueColor": {"rgbColor": {"red": 0.106, "green": 0.188, "blue": 0.216}},
                        },
                    },
                    "fields": "fontSize,foregroundColor",
                }
            })
        # Alternate row bg
        if r % 2 == 0:
            header_requests.append({
                "updateTableCellProperties": {
                    "objectId": table_id,
                    "tableRange": {
                        "location": {"rowIndex": r, "columnIndex": 0},
                        "rowSpan": 1, "columnSpan": cols,
                    },
                    "tableCellProperties": {
                        "tableCellBackgroundFill": {
                            "solidFill": {
                                "color": {"rgbColor": {"red": 0.945, "green": 0.945, "blue": 0.945}},
                            }
                        }
                    },
                    "fields": "tableCellBackgroundFill",
                }
            })

    batch_update(header_requests, token)


def upload_image_to_drive(local_path, token):
    """Upload an image to Google Drive and return a publicly accessible URL."""
    filename = os.path.basename(local_path)

    # Upload file
    result = subprocess.run([
        "curl", "-s", "-X", "POST",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-F", f"metadata={{\"name\": \"{filename}\", \"mimeType\": \"image/png\"}};type=application/json",
        "-F", f"file=@{local_path};type=image/png",
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
    ], capture_output=True, text=True)

    file_data = json.loads(result.stdout)
    file_id = file_data.get("id")
    if not file_id:
        print(f"    ERROR uploading {filename}: {result.stdout[:200]}")
        return None

    # Make it publicly accessible
    subprocess.run([
        "curl", "-s", "-X", "POST",
        f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"role": "reader", "type": "anyone"}),
    ], capture_output=True, text=True)

    # Return the direct download URL
    url = f"https://drive.google.com/uc?id={file_id}&export=download"
    print(f"    Uploaded {filename} -> {file_id}")
    return url


def main():
    print("=" * 60)
    print("LakeTS Google Slides Presentation Builder")
    print("=" * 60)

    token = get_token()
    print(f"Presentation ID: {PRES_ID}")

    # Step 1: Delete sample slides
    print("\n[Step 1] Deleting sample slides...")
    delete_sample_slides(token)

    # Step 2: Upload diagram PNGs
    print("\n[Step 2] Uploading diagram PNGs to Google Drive...")
    diagrams_dir = os.path.expanduser(
        "~/Documents/Claude Projects/Lakebase/timeseries/diagrams"
    )
    image_urls = {}
    for slide_def in SLIDES:
        if "image" in slide_def:
            img_name = slide_def["image"]
            if img_name not in image_urls:
                local_path = os.path.join(diagrams_dir, img_name)
                if os.path.exists(local_path):
                    url = upload_image_to_drive(local_path, token)
                    if url:
                        image_urls[img_name] = url
                else:
                    print(f"    WARNING: {local_path} not found")

    # Step 3: Create all slides
    print(f"\n[Step 3] Creating {len(SLIDES)} slides...")
    for i, slide_def in enumerate(SLIDES):
        print(f"\n  [{i+1}/{len(SLIDES)}] {slide_def['id']}")
        token = get_token()  # Refresh token periodically
        create_slide(slide_def, token)

        # Add image if specified
        if "image" in slide_def and slide_def["image"] in image_urls:
            add_image_to_slide(slide_def["id"], image_urls[slide_def["image"]], token)

        # Add table if specified
        if "table" in slide_def:
            add_table_to_slide(slide_def["id"], slide_def["table"], token)

        time.sleep(0.3)

    # Step 4: Delete the temp blank slide
    print("\n[Step 4] Cleaning up temp slide...")
    batch_update([{"deleteObject": {"objectId": "temp_blank"}}], token)

    print("\n" + "=" * 60)
    print(f"DONE! Presentation URL:")
    print(f"https://docs.google.com/presentation/d/{PRES_ID}/edit")
    print("=" * 60)


if __name__ == "__main__":
    main()
