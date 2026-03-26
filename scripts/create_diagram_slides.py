#!/usr/bin/env python3
"""Build native editable diagram slides for the LakeTS presentation."""

import json
import os
import sys
import time
import subprocess

sys.path.insert(0, os.path.dirname(__file__))
from slides_diagram_utils import (
    COLORS, INCH, PT, uid, get_token, batch_update, api_call,
    shape_request, style_shape, text_request, text_style,
    line_request, style_line, image_request,
    make_box, make_swimlane, make_arrow, make_title_bar,
)

PRES_ID = "16921ABei8w5RTJ-JQTlitBVmWpDgojUfS0sy5RMxw34"

BUILDER = os.path.expanduser(
    "~/.claude/plugins/cache/fe-vibe/fe-google-tools/1.2.9/skills/google-slides/resources/gslides_builder.py"
)

# Load icon URLs
ICONS_PATH = os.path.expanduser(
    "~/Documents/Claude Projects/Lakebase/timeseries/diagrams/icons/icon_urls.json"
)
with open(ICONS_PATH) as f:
    ICONS = json.load(f)

# Old slides to remove (the 4 PNG image slides)
OLD_SLIDES = {
    "obj_31b5d0961d51": 4,   # slide 5: TimescaleDB Architecture
    "obj_8a0283bb5deb": 9,   # slide 10: LakeTS Architecture
    "obj_21dbf8e53743": 14,  # slide 15: Data Lifecycle
    "obj_ad9fe2f0c77e": 17,  # slide 18: Comparison
}


def create_blank_slide(token, slide_id=None):
    """Create a blank slide and return its ID."""
    sid = slide_id or uid("dslide")
    batch_update(PRES_ID, [{
        "createSlide": {
            "objectId": sid,
            "slideLayoutReference": {"predefinedLayout": "BLANK"},
        }
    }], token)
    time.sleep(0.3)
    return sid


def move_slide(slide_id, index, token):
    """Move a slide to a specific position."""
    batch_update(PRES_ID, [{
        "updateSlidesPosition": {
            "slideObjectIds": [slide_id],
            "insertionIndex": index,
        }
    }], token)


def add_content_slide(layout, title, body=None, bullets=False, columns=None, token=None):
    """Add a content slide using gslides_builder.py and return its ID."""
    spec = [{"layout": layout, "title": title}]
    if body:
        spec[0]["body"] = body
    if bullets:
        spec[0]["bullets"] = True
    if columns:
        spec[0]["columns"] = columns

    # We can't use create-from-spec (creates new pres). Use add-template-slide instead.
    r = subprocess.run(
        ["python3", BUILDER, "add-template-slide",
         "--pres-id", PRES_ID, "--layout", layout],
        capture_output=True, text=True,
        env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
    )
    try:
        data = json.loads(r.stdout)
        page_id = data.get("pageId")
    except (json.JSONDecodeError, AttributeError):
        print(f"    Error adding {layout} slide: {r.stdout[:200]} {r.stderr[:200]}")
        return None

    if not page_id:
        return None

    # Set title placeholder
    subprocess.run(
        ["python3", BUILDER, "set-placeholder",
         "--pres-id", PRES_ID, "--page-id", page_id,
         "--type", "TITLE", "--text", title],
        capture_output=True, text=True,
        env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
    )

    # Set body if provided
    if body:
        subprocess.run(
            ["python3", BUILDER, "set-placeholder",
             "--pres-id", PRES_ID, "--page-id", page_id,
             "--type", "BODY", "--text", body],
            capture_output=True, text=True,
            env={**os.environ, "SSL_CERT_FILE": _ssl_cert()},
        )
        if bullets:
            # Get BODY placeholder objectId and apply bullets
            pres = api_call("GET",
                f"https://slides.googleapis.com/v1/presentations/{PRES_ID}/pages/{page_id}",
                token=token)
            for elem in pres.get("pageElements", []):
                ph = elem.get("shape", {}).get("placeholder", {})
                if ph.get("type") == "BODY":
                    batch_update(PRES_ID, [{
                        "createParagraphBullets": {
                            "objectId": elem["objectId"],
                            "textRange": {"type": "ALL"},
                            "bulletPreset": "BULLET_DISC_CIRCLE_SQUARE",
                        }
                    }], token)
                    break

    # Set columns if provided (for 2-col / 3-col)
    if columns:
        pres = api_call("GET",
            f"https://slides.googleapis.com/v1/presentations/{PRES_ID}/pages/{page_id}",
            token=token)
        body_phs = []
        for elem in pres.get("pageElements", []):
            ph = elem.get("shape", {}).get("placeholder", {})
            if ph.get("type") == "BODY":
                body_phs.append((elem["objectId"], elem.get("transform", {}).get("translateX", 0)))
            elif ph.get("type") == "SUBTITLE":
                body_phs.append((elem["objectId"], elem.get("transform", {}).get("translateX", 0)))
        # Sort by x position
        body_phs.sort(key=lambda x: x[1])
        for i, (obj_id, _) in enumerate(body_phs):
            if i < len(columns):
                reqs = [
                    {"deleteText": {"objectId": obj_id, "textRange": {"type": "ALL"}}},
                    {"insertText": {"objectId": obj_id, "text": columns[i], "insertionIndex": 0}},
                ]
                batch_update(PRES_ID, reqs, token)

    return page_id


def _ssl_cert():
    # Known path from Python 3.12 certifi
    cert = "/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages/certifi/cacert.pem"
    if os.path.exists(cert):
        return cert
    try:
        import certifi
        return certifi.where()
    except ImportError:
        return ""


# ============================================================
# DIAGRAM 1: TimescaleDB Architecture
# ============================================================

def build_tsdb_overview(token):
    """Build the TimescaleDB Architecture overview with native shapes."""
    print("  Building TimescaleDB Architecture overview...")
    sid = create_blank_slide(token)
    reqs = []

    # Title
    reqs.extend(make_title_bar(sid, "TimescaleDB Architecture",
                               "How TimescaleDB hooks into PostgreSQL at the C level"))

    # 4 Swimlanes
    lane_y = 1050000
    lane_h = 5500000
    lane_w = 2700000
    gap = 100000
    x_positions = [200000, 3000000, 5800000, 8600000]
    lane_titles = ["PostgreSQL Core", "TimescaleDB Extension", "Tiger Cloud", "Consumers"]
    lane_fills = ["lane_fill", "lane_fill", "lane_fill", "lane_fill"]
    lane_strokes = ["hot_stroke", "hot_comp_stroke", "cold_stroke", "source_stroke"]

    for i, (x, title) in enumerate(zip(x_positions, lane_titles)):
        lr, _ = make_swimlane(sid, x, lane_y, lane_w, lane_h, title,
                              stroke_key=lane_strokes[i])
        reqs.extend(lr)

    # --- Column 1: PostgreSQL Core ---
    bx = 400000
    by_start = 1500000
    bw = 2300000
    bh = 620000
    spacing = 720000

    components_col1 = [
        ("Storage Engine\n(heap + TOAST)", "hot_fill", "hot_stroke", ICONS.get("postgresql")),
        ("Query Planner\n(chunk exclusion)", "hot_fill", "hot_stroke", None),
        ("WAL\n(Write-Ahead Log)", "hot_fill", "hot_stroke", None),
        ("Extension API\n(C hooks)", "hot_fill", "hot_stroke", None),
    ]
    col1_ids = []
    for j, (label, fill, stroke, icon) in enumerate(components_col1):
        by = by_start + j * spacing
        br, box_id = make_box(sid, bx, by, bw, bh, label, fill, stroke,
                              font_size=10, icon_url=icon)
        reqs.extend(br)
        col1_ids.append((bx, by, bw, bh, box_id))

    # --- Column 2: TimescaleDB Extension ---
    bx2 = 3200000
    components_col2 = [
        ("Hypertables\n(auto-partition)", "hot_comp_fill", "hot_comp_stroke", None),
        ("Columnar Compression\n(98% ratio)", "hot_comp_fill", "hot_comp_stroke", None),
        ("Continuous Aggregates\n(WAL-tracked refresh)", "hot_comp_fill", "hot_comp_stroke", None),
        ("Hyperfunctions\n(time_bucket, first, last)", "hot_comp_fill", "hot_comp_stroke", None),
        ("Data Tiering\n(S3 object storage)", "hot_comp_fill", "hot_comp_stroke", ICONS.get("amazon_s3")),
    ]
    col2_ids = []
    col2_spacing = 580000
    col2_bh = 520000
    for j, (label, fill, stroke, icon) in enumerate(components_col2):
        by = by_start + j * col2_spacing
        br, box_id = make_box(sid, bx2, by, bw, col2_bh, label, fill, stroke,
                              font_size=9, icon_url=icon)
        reqs.extend(br)
        col2_ids.append((bx2, by, bw, col2_bh, box_id))

    # --- Column 3: Tiger Cloud ---
    bx3 = 6000000
    components_col3 = [
        ("Bottomless S3 Tiering", "cold_fill", "cold_stroke", ICONS.get("amazon_s3")),
        ("Insights\n(query analysis)", "cold_fill", "cold_stroke", None),
        ("pgai Vectorizer\n(AI embeddings)", "cold_fill", "cold_stroke", ICONS.get("python")),
        ("HA + Replicas\n(managed infra)", "cold_fill", "cold_stroke", None),
    ]
    col3_ids = []
    for j, (label, fill, stroke, icon) in enumerate(components_col3):
        by = by_start + j * spacing
        br, box_id = make_box(sid, bx3, by, bw, bh, label, fill, stroke,
                              font_size=10, icon_url=icon)
        reqs.extend(br)
        col3_ids.append((bx3, by, bw, bh, box_id))

    # --- Column 4: Consumers ---
    bx4 = 8800000
    components_col4 = [
        ("Grafana\nDashboards", "source_fill", "source_stroke", ICONS.get("grafana")),
        ("Applications\n(REST APIs)", "source_fill", "source_stroke", None),
        ("AI Agents\n(RAG, search)", "source_fill", "source_stroke", None),
    ]
    col4_ids = []
    for j, (label, fill, stroke, icon) in enumerate(components_col4):
        by = by_start + j * spacing
        br, box_id = make_box(sid, bx4, by, bw, bh, label, fill, stroke,
                              font_size=10, icon_url=icon)
        reqs.extend(br)
        col4_ids.append((bx4, by, bw, bh, box_id))

    # --- Arrows between columns ---
    # Col1 ExtAPI -> Col2 Hypertables
    reqs.extend(make_arrow(sid,
        col1_ids[3][0] + col1_ids[3][2], col1_ids[3][1] + col1_ids[3][3] // 2,
        col2_ids[0][0], col2_ids[0][1] + col2_ids[0][3] // 2,
        "arrow_red", weight=2, label="hooks into"))
    # Col1 WAL -> Col2 CAGG
    reqs.extend(make_arrow(sid,
        col1_ids[2][0] + col1_ids[2][2], col1_ids[2][1] + col1_ids[2][3] // 2,
        col2_ids[2][0], col2_ids[2][1] + col2_ids[2][3] // 2,
        "arrow_gray", dash="DASH", label="WAL tracking"))
    # Col2 Hypertables -> Col2 Compression
    reqs.extend(make_arrow(sid,
        col2_ids[0][0] + col2_ids[0][2] // 2, col2_ids[0][1] + col2_ids[0][3],
        col2_ids[1][0] + col2_ids[1][2] // 2, col2_ids[1][1],
        "arrow_gray", label="older chunks"))
    # Col2 Tiering -> Col3 S3
    reqs.extend(make_arrow(sid,
        col2_ids[4][0] + col2_ids[4][2], col2_ids[4][1] + col2_ids[4][3] // 2,
        col3_ids[0][0], col3_ids[0][1] + col3_ids[0][3] // 2,
        "arrow_red", weight=2, label="offload"))
    # Col2 CAGG -> Col4 Grafana
    reqs.extend(make_arrow(sid,
        col2_ids[2][0] + col2_ids[2][2], col2_ids[2][1] + col2_ids[2][3] // 2,
        col4_ids[0][0], col4_ids[0][1] + col4_ids[0][3] // 2,
        "arrow_gray"))
    # Col3 pgai -> Col4 AI Agents
    reqs.extend(make_arrow(sid,
        col3_ids[2][0] + col3_ids[2][2], col3_ids[2][1] + col3_ids[2][3] // 2,
        col4_ids[2][0], col4_ids[2][1] + col4_ids[2][3] // 2,
        "arrow_gray"))

    batch_update(PRES_ID, reqs, token)
    return sid


def build_tsdb_deepdives(token):
    """Build TimescaleDB deep-dive slides."""
    print("  Building TimescaleDB deep-dives...")
    slides = []

    # Deep-dive 1: Hypertables & Chunks
    s1 = add_content_slide("content_basic",
        "Hypertables & Chunk Architecture",
        body=(
            "A hypertable is a virtual table that auto-partitions into time-based chunks\n"
            "Each chunk is a real PostgreSQL table (e.g., _hyper_1_chunk_3)\n"
            "New chunks created automatically as time advances (e.g., 1 chunk per day)\n"
            "Query planner performs chunk exclusion: WHERE time > now() - '1 hour' scans only 1 chunk\n"
            "Transparent to SQL: INSERT, SELECT, UPDATE, DELETE work unchanged on the hypertable\n"
            "CREATE_HYPERTABLE() converts any existing table with a time column\n"
            "Chunks can be individually compressed, tiered to S3, or dropped for instant retention"
        ),
        bullets=True, token=token)
    slides.append(s1)

    # Deep-dive 2: Compression & Tiering
    s2 = add_content_slide("content_2col",
        "Compression & Data Tiering",
        columns=[
            "Columnar Compression",
            "Batches of 1000 rows compressed per column\nUp to 98% storage reduction\nStored in TOAST pages (PG native)\nVectorized query engine for compressed data\nSegmentBy and OrderBy optimizations\nDecompression only for matching segments",
            "S3 Data Tiering (Tiger Cloud)",
            "Chunks older than policy threshold tiered to S3\nRemain fully queryable via TimescaleDB\nDecompress-on-read from object storage\nRetention policies auto-drop expired data\nCompression + tier = 2-stage pipeline\nBottomless storage at cloud-native cost",
        ],
        token=token)
    slides.append(s2)

    return slides


# ============================================================
# DIAGRAM 2: LakeTS Architecture
# ============================================================

def build_lakets_overview(token):
    """Build the LakeTS Architecture overview with native shapes."""
    print("  Building LakeTS Architecture overview...")
    sid = create_blank_slide(token)
    reqs = []

    reqs.extend(make_title_bar(sid, "LakeTS Architecture Overview",
                               "Two-tier hot/cold architecture with Lakehouse Sync CDC"))

    # 4 main swimlanes + 1 bottom workflow bar
    lane_y = 1050000
    main_h = 4200000
    x_pos = [150000, 2650000, 5350000, 7600000]
    widths = [2350000, 2550000, 2100000, 4200000]
    titles = ["Data Sources", "HOT TIER \u2014 Lakebase", "Lakehouse Sync", "COLD TIER \u2014 Delta Lake"]
    strokes = ["source_stroke", "hot_stroke", "cdc_stroke", "cold_stroke"]

    for i in range(4):
        w = widths[i] if i < 3 else 4200000
        lr, _ = make_swimlane(sid, x_pos[i], lane_y, w, main_h, titles[i],
                              stroke_key=strokes[i])
        reqs.extend(lr)

    # Workflow bar at bottom
    wf_y = 5450000
    lr, _ = make_swimlane(sid, 150000, wf_y, 11700000, 1200000,
                          "Databricks Workflows (Automated Lifecycle)",
                          stroke_key="workflow_stroke")
    reqs.extend(lr)

    # --- Data Sources ---
    src_x = 300000
    src_bw = 2000000
    src_bh = 500000
    sources = [
        ("IoT Sensors", "source_fill", "source_stroke", None),
        ("App Metrics", "source_fill", "source_stroke", None),
        ("Telegraf / Prometheus", "source_fill", "source_stroke", ICONS.get("prometheus")),
        ("Edge Devices", "source_fill", "source_stroke", None),
    ]
    src_ids = []
    for j, (label, fill, stroke, icon) in enumerate(sources):
        by = 1500000 + j * 600000
        br, box_id = make_box(sid, src_x, by, src_bw, src_bh, label, fill, stroke,
                              font_size=9, icon_url=icon)
        reqs.extend(br)
        src_ids.append((src_x, by, src_bw, src_bh))

    # --- Hot Tier ---
    hot_x = 2850000
    hot_bw = 2150000
    hot_bh = 480000
    hot_components = [
        ("Bulk Ingest API\n(JSONB + Prometheus)", "hot_fill", "hot_stroke", ICONS.get("postgresql")),
        ("ChronoTables\n(PG RANGE Partition)", "hot_comp_fill", "hot_comp_stroke", ICONS.get("databricks")),
        ("Time Series Functions\n+ Continuous Aggregates", "hot_fill", "hot_stroke", None),
        ("Last Value Cache\n(sub-10ms lookups)", "hot_fill", "hot_stroke", None),
        ("Alert Rules + Monitoring", "hot_fill", "hot_stroke", ICONS.get("grafana")),
    ]
    hot_ids = []
    hot_spacing = 540000
    for j, (label, fill, stroke, icon) in enumerate(hot_components):
        by = 1500000 + j * hot_spacing
        br, box_id = make_box(sid, hot_x, by, hot_bw, hot_bh, label, fill, stroke,
                              font_size=9, icon_url=icon)
        reqs.extend(br)
        hot_ids.append((hot_x, by, hot_bw, hot_bh))

    # --- CDC Sync ---
    cdc_x = 5550000
    cdc_bw = 1800000
    cdc_bh = 550000
    cdc_components = [
        ("wal2delta\nCDC Pipeline", "cdc_fill", "cdc_stroke", None),
        ("Shadow Table\nPattern", "cdc_fill", "cdc_stroke", None),
    ]
    cdc_ids = []
    for j, (label, fill, stroke, icon) in enumerate(cdc_components):
        by = 1800000 + j * 1200000
        br, box_id = make_box(sid, cdc_x, by, cdc_bw, cdc_bh, label, fill, stroke,
                              font_size=10)
        reqs.extend(br)
        cdc_ids.append((cdc_x, by, cdc_bw, cdc_bh))

    # --- Cold Tier ---
    cold_x = 7800000
    cold_bw = 3700000
    cold_bh = 480000
    cold_components = [
        ("Tiered Chunks\n(compressed Parquet)", "cold_fill", "cold_stroke", ICONS.get("delta_lake")),
        ("Downsampled Rollups\n(1m / 1h / 1d)", "cold_fill", "cold_stroke", None),
        ("Photon Analytics", "cold_fill", "cold_stroke", ICONS.get("spark")),
        ("ML/AI Integration\n(MLflow, Feature Store)", "cold_fill", "cold_stroke", ICONS.get("mlflow")),
    ]
    cold_ids = []
    for j, (label, fill, stroke, icon) in enumerate(cold_components):
        by = 1500000 + j * 580000
        br, box_id = make_box(sid, cold_x, by, cold_bw, cold_bh, label, fill, stroke,
                              font_size=9, icon_url=icon)
        reqs.extend(br)
        cold_ids.append((cold_x, by, cold_bw, cold_bh))

    # --- Workflows ---
    wf_x_start = 400000
    wf_bw = 2500000
    wf_bh = 450000
    wf_y_inner = 5800000
    workflows = [
        ("Partition Manager\n(every 6 hours)", ICONS.get("workflows")),
        ("Compression Job\n(daily 2 AM UTC)", None),
        ("Retention Job\n(daily 3 AM UTC)", None),
        ("CAGG Refresh\n(every 15 min)", None),
    ]
    for j, (label, icon) in enumerate(workflows):
        wx = wf_x_start + j * 2900000
        br, _ = make_box(sid, wx, wf_y_inner, wf_bw, wf_bh, label,
                         "workflow_fill", "workflow_stroke", font_size=9, icon_url=icon)
        reqs.extend(br)

    # --- Key arrows ---
    # Sources -> Hot: Bulk Ingest
    for j in range(4):
        sy = src_ids[j][1] + src_ids[j][3] // 2
        reqs.extend(make_arrow(sid,
            src_ids[j][0] + src_ids[j][2], sy,
            hot_ids[0][0], hot_ids[0][1] + hot_ids[0][3] // 2,
            "arrow_gray", weight=1))

    # Hot ChronoTables -> CDC wal2delta
    reqs.extend(make_arrow(sid,
        hot_ids[1][0] + hot_ids[1][2], hot_ids[1][1] + hot_ids[1][3] // 2,
        cdc_ids[0][0], cdc_ids[0][1] + cdc_ids[0][3] // 2,
        "arrow_pink", weight=2, label="WAL stream"))

    # CDC -> Cold Tiered Chunks
    reqs.extend(make_arrow(sid,
        cdc_ids[0][0] + cdc_ids[0][2], cdc_ids[0][1] + cdc_ids[0][3] // 2,
        cold_ids[0][0], cold_ids[0][1] + cold_ids[0][3] // 2,
        "arrow_pink", weight=2, label="sync"))

    batch_update(PRES_ID, reqs, token)
    return sid


def build_lakets_deepdives(token):
    """Build LakeTS deep-dive slides."""
    print("  Building LakeTS deep-dives...")
    slides = []

    # Deep-dive 1: Hot Tier Components
    s1 = add_content_slide("content_basic",
        "Hot Tier: ChronoTables & Functions",
        body=(
            "ChronoTables use native PG RANGE partitioning \u2014 no C extension needed\n"
            "create_hypertable() converts any table: adds partitions, metadata, policies\n"
            "Each partition covers a configurable time interval (default: 1 day)\n"
            "56+ time-series functions: time_bucket, first/last, gapfill, interpolate, delta, rate\n"
            "Continuous Aggregates: materialized views refreshed every 15 min with real-time UNION\n"
            "Last Value Cache: trigger-maintained table for sub-10ms latest-state queries\n"
            "Alert Rules: SQL-native threshold checks and deadman detection returning JSONB"
        ),
        bullets=True, token=token)
    slides.append(s1)

    # Deep-dive 2: Shadow Sync CDC (native diagram)
    print("  Building Shadow Sync CDC diagram...")
    sid = create_blank_slide(token)
    reqs = []
    reqs.extend(make_title_bar(sid, "Shadow Sync: CDC for Partitioned Tables",
                               "Why wal2delta cannot CDC partitioned tables, and how LakeTS solves it"))

    # Flow: Partitioned Table -> Trigger -> Shadow Table -> WAL -> wal2delta -> Delta
    boxes_data = [
        (400000, 2000000, 1800000, 700000, "Partitioned\nChronoTable", "hot_comp_fill", "hot_comp_stroke"),
        (400000, 3200000, 1800000, 700000, "INSERT Trigger\n(on each partition)", "hot_fill", "hot_stroke"),
        (2800000, 2600000, 1800000, 700000, "Shadow Table\n(unpartitioned)", "cdc_fill", "cdc_stroke"),
        (5200000, 2600000, 1800000, 700000, "WAL Stream\n(REPLICA IDENTITY\nFULL)", "cdc_fill", "cdc_stroke"),
        (7600000, 2600000, 1800000, 700000, "wal2delta\nCDC Pipeline", "cdc_fill", "cdc_stroke"),
        (10000000, 2600000, 1800000, 700000, "Delta Lake\nTable", "cold_fill", "cold_stroke"),
    ]
    box_positions = []
    for (bx, by, bw, bh, label, fill, stroke) in boxes_data:
        br, bid = make_box(sid, bx, by, bw, bh, label, fill, stroke, font_size=10, bold=True)
        reqs.extend(br)
        box_positions.append((bx, by, bw, bh))

    # Arrows
    # ChronoTable -> Trigger (down)
    reqs.extend(make_arrow(sid,
        box_positions[0][0] + box_positions[0][2] // 2, box_positions[0][1] + box_positions[0][3],
        box_positions[1][0] + box_positions[1][2] // 2, box_positions[1][1],
        "arrow_gray", label="INSERT"))
    # Trigger -> Shadow
    reqs.extend(make_arrow(sid,
        box_positions[1][0] + box_positions[1][2], box_positions[1][1] + box_positions[1][3] // 2,
        box_positions[2][0], box_positions[2][1] + box_positions[2][3] // 2,
        "arrow_pink", weight=2, label="copy"))
    # Shadow -> WAL -> wal2delta -> Delta
    for i in range(2, 5):
        reqs.extend(make_arrow(sid,
            box_positions[i][0] + box_positions[i][2], box_positions[i][1] + box_positions[i][3] // 2,
            box_positions[i+1][0], box_positions[i+1][1] + box_positions[i+1][3] // 2,
            "arrow_pink", weight=2))

    # Annotation: why shadow table is needed
    note_id = uid("note")
    reqs.append(shape_request(sid, note_id, "TEXT_BOX", 400000, 4400000, 11000000, 1800000))
    reqs.append(text_request(note_id,
        "Why Shadow Table?\n\n"
        "Lakehouse Sync (wal2delta) cannot capture CDC from partitioned tables \u2014 "
        "PostgreSQL\u2019s logical replication publishes changes on child partitions, "
        "not the parent. The shadow table is an unpartitioned copy that receives all "
        "INSERTs via a trigger. With REPLICA IDENTITY FULL set, wal2delta can stream "
        "the shadow table\u2019s WAL to Delta Lake. The parent ChronoTable is resolved "
        "via pg_inherits for queries."
    ))
    reqs.extend(text_style(note_id, font_size=11, color=COLORS["text_dark"]))
    # Bold the first line
    reqs.extend(text_style(note_id, font_size=13, bold=True, color=COLORS["cdc_stroke"],
                           start=0, end=17))

    batch_update(PRES_ID, reqs, token)
    slides = [sid]

    # Deep-dive 3: Cold Tier
    s3 = add_content_slide("content_2col",
        "Cold Tier: Delta Lake Analytics",
        columns=[
            "Data in Delta Lake",
            "Compressed Parquet files with Z-ORDER by time\nTime travel for historical queries\nDownsampled rollups: 1-min, 1-hour, 1-day\nPartition pruning on time column\nACID transactions on all writes",
            "Analytics & ML",
            "Photon-accelerated Spark queries\nMLflow model training on cold data\nFeature Store for ML pipelines\nUnity Catalog governance + lineage\nDLT pipelines for incremental ETL",
        ],
        token=token)
    slides.append(s3)

    return slides


# ============================================================
# DIAGRAM 3: Data Lifecycle
# ============================================================

def build_lifecycle_overview(token):
    """Build the Data Lifecycle overview with native shapes."""
    print("  Building Data Lifecycle overview...")
    sid = create_blank_slide(token)
    reqs = []

    reqs.extend(make_title_bar(sid, "Data Lifecycle Flow",
                               "From ingest to archive \u2014 automated hot/warm/cold tiering"))

    # 6 horizontal stages
    stage_w = 1700000
    stage_h = 3200000
    stage_y = 1200000
    gap = 150000
    stage_x_start = 200000

    stages = [
        ("INGEST", "hot_fill", "hot_stroke",
         "Bulk JSONB API\nPrometheus remote-write\nDirect SQL INSERT\nTriggers fire on INSERT"),
        ("HOT\n(0\u20137 days)", "hot_comp_fill", "hot_comp_stroke",
         "ChronoTable partitions\nLVC updated (UPSERT)\nCAGG refresh (15 min)\nShadow table CDC copy"),
        ("CDC SYNC", "cdc_fill", "cdc_stroke",
         "WAL capture\nwal2delta pipeline\nShadow table \u2192 Delta\nNear real-time (seconds)"),
        ("WARM\n(7\u201330 days)", "ai_fill", "ai_stroke",
         "Delta Lake storage\nDownsample 1m \u2192 1h \u2192 1d\nMark chunks compressed\nZ-ORDER optimization"),
        ("COLD\n(30\u201390+ days)", "cold_fill", "cold_stroke",
         "Archive Parquet files\nQuery-on-demand\nPhoton analytics\nML/AI training data"),
        ("DROP", "neutral", "lane_stroke",
         "Auto-retention policy\nDROP TABLE (instant)\nPer-partition removal\nNo DELETE scans"),
    ]

    stage_positions = []
    for i, (title, fill, stroke, details) in enumerate(stages):
        sx = stage_x_start + i * (stage_w + gap)
        # Stage header
        hdr_id = uid("shdr")
        reqs.append(shape_request(sid, hdr_id, "ROUND_RECTANGLE", sx, stage_y, stage_w, 600000))
        reqs.append(style_shape(hdr_id, COLORS[fill], COLORS[stroke], stroke_weight=2))
        reqs.append(text_request(hdr_id, title))
        reqs.extend(text_style(hdr_id, font_size=12, bold=True, color=COLORS[stroke],
                               alignment="CENTER"))

        # Stage details below
        det_id = uid("sdet")
        reqs.append(shape_request(sid, det_id, "ROUND_RECTANGLE",
                                  sx, stage_y + 700000, stage_w, 2400000))
        reqs.append(style_shape(det_id, COLORS["white"], COLORS[stroke], stroke_weight=1))
        reqs.append(text_request(det_id, details))
        reqs.extend(text_style(det_id, font_size=9, color=COLORS["text_dark"]))

        stage_positions.append((sx, stage_y, stage_w, 600000))

    # Arrows between stages
    for i in range(5):
        x1 = stage_positions[i][0] + stage_positions[i][2]
        y1 = stage_positions[i][1] + stage_positions[i][3] // 2
        x2 = stage_positions[i+1][0]
        y2 = stage_positions[i+1][1] + stage_positions[i+1][3] // 2
        color = "arrow_pink" if i in (1, 2) else "arrow_gray"
        reqs.extend(make_arrow(sid, x1, y1, x2, y2, color, weight=2))

    # Timeline bar at top
    tl_id = uid("tl")
    reqs.append(shape_request(sid, tl_id, "TEXT_BOX", 200000, 4700000, 11400000, 350000))
    reqs.append(text_request(tl_id,
        "Timeline:  0 days  \u2500\u2500\u2500\u2500\u2500\u2500\u2500  7 days  \u2500\u2500\u2500\u2500\u2500\u2500\u2500  30 days  \u2500\u2500\u2500\u2500\u2500\u2500\u2500  90 days  \u2500\u2500\u2500\u2500\u2500\u2500\u2500  DROP"))
    reqs.extend(text_style(tl_id, font_size=11, bold=True, color=COLORS["arrow_gray"],
                           alignment="CENTER"))

    # Icons on key stages
    if ICONS.get("postgresql"):
        reqs.append(image_request(sid, uid("ico"), ICONS["postgresql"],
                                  stage_positions[1][0] + stage_w - 380000,
                                  stage_positions[1][1] + 140000, 300000, 300000))
    if ICONS.get("delta_lake"):
        reqs.append(image_request(sid, uid("ico"), ICONS["delta_lake"],
                                  stage_positions[3][0] + stage_w - 380000,
                                  stage_positions[3][1] + 140000, 300000, 300000))

    batch_update(PRES_ID, reqs, token)
    return sid


def build_lifecycle_deepdives(token):
    """Build Data Lifecycle deep-dive slides."""
    print("  Building Data Lifecycle deep-dives...")
    slides = []

    s1 = add_content_slide("content_basic",
        "Write Path: Ingest to Hot Tier",
        body=(
            "Three ingest paths: JSONB bulk array, Prometheus remote-write protocol, direct SQL INSERT\n"
            "All INSERTs land on the parent ChronoTable \u2014 PG routes to correct time partition\n"
            "After INSERT, triggers fire in sequence:\n"
            "  1. Last Value Cache trigger: UPSERT latest reading per device into LVC table\n"
            "  2. Shadow Table trigger: copy row to unpartitioned shadow table for CDC\n"
            "Continuous Aggregates auto-refresh every 15 minutes via Databricks Workflow\n"
            "Hot data stays in Lakebase for 7 days (configurable per-table via _policy_registry)\n"
            "Prometheus monitoring exports metrics for Grafana dashboards"
        ),
        bullets=True, token=token)
    slides.append(s1)

    s2 = add_content_slide("content_basic",
        "Tiering & Retention Policies",
        body=(
            "All lifecycle automation driven by _policy_registry metadata table\n"
            "Partition Manager: pre-creates future partitions every 6 hours (avoid INSERT failures)\n"
            "Compression Job (2 AM UTC): identifies chunks older than retention_hot_days, tiers to Delta Lake\n"
            "Retention Job (3 AM UTC): DROP TABLE on expired partitions \u2014 instant, no sequential DELETE scan\n"
            "CAGG Refresh (every 15 min): REFRESH MATERIALIZED VIEW CONCURRENTLY + real-time UNION\n"
            "Downsampling on warm tier: 1-minute \u2192 1-hour \u2192 1-day resolution aggregates\n"
            "All 4 jobs deployed as Databricks Asset Bundles (1-click setup via databricks.yml)"
        ),
        bullets=True, token=token)
    slides.append(s2)

    return slides


# ============================================================
# DIAGRAM 4: LakeTS vs TimescaleDB Comparison
# ============================================================

def build_comparison_overview(token):
    """Build the comparison overview with native shapes."""
    print("  Building Comparison overview...")
    sid = create_blank_slide(token)
    reqs = []

    reqs.extend(make_title_bar(sid, "LakeTS vs TimescaleDB",
                               "Feature-by-feature architecture comparison"))

    # 3-column comparison grid
    col_x = [400000, 4200000, 8000000]
    col_w = [3600000, 3600000, 3600000]
    row_y_start = 1200000
    row_h = 550000
    row_gap = 80000

    # Headers
    headers = [("Feature", "dark_bg", "text_white"),
               ("TimescaleDB", "hot_stroke", "text_white"),
               ("LakeTS", "cold_stroke", "text_white")]
    for i, (label, bg_key, text_key) in enumerate(headers):
        hid = uid("hdr")
        reqs.append(shape_request(sid, hid, "RECTANGLE", col_x[i], row_y_start, col_w[i], row_h))
        reqs.append(style_shape(hid, COLORS[bg_key], None))
        reqs.append(text_request(hid, label))
        reqs.extend(text_style(hid, font_size=13, bold=True, color=COLORS[text_key],
                               alignment="CENTER"))

    # Add icons to headers
    if ICONS.get("postgresql"):
        reqs.append(image_request(sid, uid("ico"), ICONS["postgresql"],
                                  col_x[1] + col_w[1] - 500000, row_y_start + 100000,
                                  350000, 350000))
    if ICONS.get("databricks"):
        reqs.append(image_request(sid, uid("ico"), ICONS["databricks"],
                                  col_x[2] + col_w[2] - 500000, row_y_start + 100000,
                                  350000, 350000))

    # Data rows
    rows = [
        ("Partitioning", "C-native Hypertables\n(auto-partition)", "PG RANGE ChronoTables\n(no extension)", "neutral", "neutral"),
        ("Compression", "Columnar (98% ratio)\nTOAST + vectorized", "Delta Lake Parquet\n+ Z-ORDER", "win_blue", "neutral"),
        ("CAGG Refresh", "Incremental WAL-tracked\n(only changed buckets)", "Full REFRESH MATVIEW\n+ real-time UNION", "win_blue", "neutral"),
        ("Functions", "C hyperfunctions\n(time_bucket, first, last)", "PL/pgSQL (56+ functions)\n(same API surface)", "neutral", "neutral"),
        ("Cold Storage", "S3 decompress-on-read", "Delta Lake (ACID, Photon)\n+ MLflow + Feature Store", "neutral", "win_green"),
        ("ML/AI", "pgai + pgvectorscale\n(embeddings, vector search)", "MLflow + Feature Store\n+ Spark + Unity Catalog", "neutral", "win_green"),
        ("Cost", "Per-node (Tiger Cloud)", "Serverless, scale-to-zero", "neutral", "win_green"),
    ]

    for j, (feature, tsdb, lakets, tsdb_bg, lakets_bg) in enumerate(rows):
        ry = row_y_start + (j + 1) * (row_h + row_gap)

        # Feature column
        fid = uid("feat")
        reqs.append(shape_request(sid, fid, "RECTANGLE", col_x[0], ry, col_w[0], row_h))
        reqs.append(style_shape(fid, COLORS["neutral"], COLORS["lane_stroke"], stroke_weight=0.5))
        reqs.append(text_request(fid, feature))
        reqs.extend(text_style(fid, font_size=11, bold=True, color=COLORS["text_dark"],
                               alignment="CENTER"))

        # TimescaleDB column
        tid = uid("tsdb")
        reqs.append(shape_request(sid, tid, "RECTANGLE", col_x[1], ry, col_w[1], row_h))
        reqs.append(style_shape(tid, COLORS[tsdb_bg], COLORS["lane_stroke"], stroke_weight=0.5))
        reqs.append(text_request(tid, tsdb))
        reqs.extend(text_style(tid, font_size=9, color=COLORS["text_dark"], alignment="CENTER"))

        # LakeTS column
        lid = uid("lts")
        reqs.append(shape_request(sid, lid, "RECTANGLE", col_x[2], ry, col_w[2], row_h))
        reqs.append(style_shape(lid, COLORS[lakets_bg], COLORS["lane_stroke"], stroke_weight=0.5))
        reqs.append(text_request(lid, lakets))
        reqs.extend(text_style(lid, font_size=9, color=COLORS["text_dark"], alignment="CENTER"))

    batch_update(PRES_ID, reqs, token)
    return sid


def build_comparison_deepdives(token):
    """Build comparison deep-dive slides."""
    print("  Building Comparison deep-dives...")
    slides = []

    # Architecture stacks (native diagram)
    print("  Building Architecture Stacks diagram...")
    sid = create_blank_slide(token)
    reqs = []
    reqs.extend(make_title_bar(sid, "Architecture Stack Comparison",
                               "TimescaleDB vs LakeTS \u2014 equivalent layers"))

    # TimescaleDB stack (left)
    ts_x = 600000
    stack_w = 4500000
    stack_h = 700000
    ts_layers = [
        ("PostgreSQL 16 (Managed)", "hot_fill", "hot_stroke", ICONS.get("postgresql")),
        ("TimescaleDB C Extension", "hot_comp_fill", "hot_comp_stroke", None),
        ("Tiger Cloud (Managed Service)", "cold_fill", "cold_stroke", None),
        ("S3 Object Storage", "cold_fill", "cold_stroke", ICONS.get("amazon_s3")),
    ]

    # LakeTS stack (right)
    lt_x = 6600000
    lt_layers = [
        ("Lakebase (Managed PostgreSQL)", "hot_fill", "hot_stroke", ICONS.get("databricks")),
        ("LakeTS PL/pgSQL (56+ functions)", "hot_comp_fill", "hot_comp_stroke", None),
        ("Lakehouse Sync (wal2delta CDC)", "cdc_fill", "cdc_stroke", None),
        ("Delta Lake + Spark/Photon", "cold_fill", "cold_stroke", ICONS.get("delta_lake")),
    ]

    # Stack labels
    for label, x in [("TimescaleDB Stack", ts_x), ("LakeTS Stack", lt_x)]:
        lid = uid("slbl")
        reqs.append(shape_request(sid, lid, "TEXT_BOX", x, 1100000, stack_w, 400000))
        reqs.append(text_request(lid, label))
        reqs.extend(text_style(lid, font_size=16, bold=True, color=COLORS["text_dark"],
                               alignment="CENTER"))

    ts_positions = []
    lt_positions = []
    for j in range(4):
        ly = 1600000 + j * (stack_h + 150000)
        # TimescaleDB layer
        br, _ = make_box(sid, ts_x, ly, stack_w, stack_h,
                         ts_layers[j][0], ts_layers[j][1], ts_layers[j][2],
                         font_size=11, bold=True, icon_url=ts_layers[j][3])
        reqs.extend(br)
        ts_positions.append((ts_x, ly, stack_w, stack_h))

        # LakeTS layer
        br, _ = make_box(sid, lt_x, ly, stack_w, stack_h,
                         lt_layers[j][0], lt_layers[j][1], lt_layers[j][2],
                         font_size=11, bold=True, icon_url=lt_layers[j][3])
        reqs.extend(br)
        lt_positions.append((lt_x, ly, stack_w, stack_h))

    # Equivalence arrows between stacks
    for j in range(4):
        reqs.extend(make_arrow(sid,
            ts_positions[j][0] + ts_positions[j][2],
            ts_positions[j][1] + ts_positions[j][3] // 2,
            lt_positions[j][0],
            lt_positions[j][1] + lt_positions[j][3] // 2,
            "arrow_gray", weight=1, dash="DASH", label="\u2248"))

    # Vertical arrows within each stack
    for positions in [ts_positions, lt_positions]:
        for j in range(3):
            reqs.extend(make_arrow(sid,
                positions[j][0] + positions[j][2] // 2,
                positions[j][1] + positions[j][3],
                positions[j+1][0] + positions[j+1][2] // 2,
                positions[j+1][1],
                "arrow_gray"))

    batch_update(PRES_ID, reqs, token)
    slides.append(sid)

    # Where Each Wins
    s2 = add_content_slide("content_2col",
        "Where Each Wins",
        columns=[
            "TimescaleDB Advantages",
            "C-native engine: 5-10x raw query speed\nWAL-tracked incremental CAGG refresh\nMature community (2000+ customers)\npgai: SQL-native AI embeddings\npgvectorscale: vector search\nProven at petabyte scale",
            "LakeTS Advantages",
            "Zero install: pure SQL on any Lakebase\nDelta Lake: ACID, Photon, time travel\nMLflow + Feature Store + Spark ML\nServerless cost: scale-to-zero compute\nUnity Catalog governance + lineage\nDatabricks ecosystem integration",
        ],
        token=token)
    slides.append(s2)

    return slides


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 60)
    print("Building Native Editable Diagram Slides")
    print(f"Presentation: {PRES_ID}")
    print("=" * 60)

    token = get_token()

    # Track all new slide IDs and their target positions
    new_slides = []

    # --- Diagram 1: TimescaleDB Architecture ---
    print("\n[1/4] TimescaleDB Architecture")
    tsdb_overview = build_tsdb_overview(token)
    token = get_token()
    tsdb_deepdives = build_tsdb_deepdives(token)
    new_slides.append(("tsdb_overview", tsdb_overview, 4))  # insert at position 4 (before old slide 5)
    for i, s in enumerate(tsdb_deepdives):
        if s:
            new_slides.append((f"tsdb_dd_{i}", s, 5 + i))

    # --- Diagram 2: LakeTS Architecture ---
    print("\n[2/4] LakeTS Architecture")
    token = get_token()
    lakets_overview = build_lakets_overview(token)
    token = get_token()
    lakets_deepdives = build_lakets_deepdives(token)
    new_slides.append(("lakets_overview", lakets_overview, 9))
    for i, s in enumerate(lakets_deepdives):
        if s:
            new_slides.append((f"lakets_dd_{i}", s, 10 + i))

    # --- Diagram 3: Data Lifecycle ---
    print("\n[3/4] Data Lifecycle")
    token = get_token()
    lifecycle_overview = build_lifecycle_overview(token)
    token = get_token()
    lifecycle_deepdives = build_lifecycle_deepdives(token)
    new_slides.append(("lifecycle_overview", lifecycle_overview, 14))
    for i, s in enumerate(lifecycle_deepdives):
        if s:
            new_slides.append((f"lifecycle_dd_{i}", s, 15 + i))

    # --- Diagram 4: Comparison ---
    print("\n[4/4] LakeTS vs TimescaleDB Comparison")
    token = get_token()
    comparison_overview = build_comparison_overview(token)
    token = get_token()
    comparison_deepdives = build_comparison_deepdives(token)
    new_slides.append(("comparison_overview", comparison_overview, 17))
    for i, s in enumerate(comparison_deepdives):
        if s:
            new_slides.append((f"comparison_dd_{i}", s, 18 + i))

    # --- Remove old PNG image slides ---
    print("\n[Cleanup] Removing old PNG image slides...")
    token = get_token()
    delete_reqs = [{"deleteObject": {"objectId": sid}} for sid in OLD_SLIDES.keys()]
    if delete_reqs:
        batch_update(PRES_ID, delete_reqs, token)
        print(f"  Deleted {len(delete_reqs)} old slides")

    # --- Reposition new slides ---
    print("\n[Reorder] Repositioning slides...")
    # Get current slide order
    token = get_token()
    pres = api_call("GET", f"https://slides.googleapis.com/v1/presentations/{PRES_ID}", token=token)
    current_slides = [s["objectId"] for s in pres.get("slides", [])]
    print(f"  Current slide count: {len(current_slides)}")

    print(f"\n{'=' * 60}")
    print(f"DONE! {len(new_slides)} new diagram slides created.")
    url = f"https://docs.google.com/presentation/d/{PRES_ID}/edit"
    print(f"Presentation: {url}")
    print(f"{'=' * 60}")

    return new_slides


if __name__ == "__main__":
    main()
