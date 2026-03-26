#!/usr/bin/env python3
"""Utility functions for building native editable diagrams in Google Slides."""

import json
import subprocess
import uuid

QUOTA_PROJECT = "gcp-sandbox-field-eng"

# --- Databricks Brand Colors ---
COLORS = {
    # Functional fills (light backgrounds)
    "hot_fill": {"red": 0.89, "green": 0.95, "blue": 0.99},       # #E3F2FD
    "hot_stroke": {"red": 0.08, "green": 0.40, "blue": 0.75},     # #1565C0
    "hot_comp_fill": {"red": 1.0, "green": 0.95, "blue": 0.88},   # #FFF3E0
    "hot_comp_stroke": {"red": 0.90, "green": 0.32, "blue": 0.0}, # #E65100
    "cold_fill": {"red": 0.91, "green": 0.96, "blue": 0.91},      # #E8F5E9
    "cold_stroke": {"red": 0.18, "green": 0.49, "blue": 0.20},    # #2E7D32
    "cdc_fill": {"red": 1.0, "green": 0.92, "blue": 0.93},        # #FFEBEE
    "cdc_stroke": {"red": 0.78, "green": 0.16, "blue": 0.16},     # #C62828
    "workflow_fill": {"red": 0.91, "green": 0.92, "blue": 0.96},  # #E8EAF6
    "workflow_stroke": {"red": 0.16, "green": 0.21, "blue": 0.58},# #283593
    "source_fill": {"red": 0.95, "green": 0.90, "blue": 0.96},    # #F3E5F5
    "source_stroke": {"red": 0.42, "green": 0.11, "blue": 0.60},  # #6A1B9A
    "ai_fill": {"red": 1.0, "green": 0.95, "blue": 0.88},         # #FFF3E0
    "ai_stroke": {"red": 0.90, "green": 0.42, "blue": 0.0},       # #E66B00
    # Swimlane / container
    "lane_fill": {"red": 0.98, "green": 0.98, "blue": 0.98},      # #FAFAFA
    "lane_stroke": {"red": 0.56, "green": 0.64, "blue": 0.68},    # #90A4AE
    # Lines
    "arrow_gray": {"red": 0.47, "green": 0.56, "blue": 0.61},     # #78909C
    "arrow_red": {"red": 1.0, "green": 0.21, "blue": 0.13},       # #FF3621
    "arrow_pink": {"red": 0.85, "green": 0.11, "blue": 0.38},     # #D81B60
    # Text
    "text_dark": {"red": 0.11, "green": 0.19, "blue": 0.22},      # #1B3037
    "text_white": {"red": 1.0, "green": 1.0, "blue": 1.0},
    # Dark bg for headers
    "dark_bg": {"red": 0.11, "green": 0.19, "blue": 0.22},        # #1B3037
    "teal_bg": {"red": 0.11, "green": 0.32, "blue": 0.38},        # #1B5161
    # Win colors for comparison
    "win_blue": {"red": 0.88, "green": 0.94, "blue": 1.0},        # #E0F0FF
    "win_green": {"red": 0.88, "green": 0.97, "blue": 0.90},      # #E0F8E6
    "neutral": {"red": 0.96, "green": 0.96, "blue": 0.96},        # #F5F5F5
    "white": {"red": 1.0, "green": 1.0, "blue": 1.0},
}

# EMU helpers
INCH = 914400
PT = 12700


def uid(prefix="el"):
    """Generate a unique element ID."""
    return f"{prefix}_{uuid.uuid4().hex[:10]}"


def get_token():
    """Get gcloud access token."""
    r = subprocess.run(
        ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
         "auth", "application-default", "print-access-token"],
        capture_output=True, text=True,
    )
    return r.stdout.strip()


def api_call(method, url, data=None, token=None):
    """Make an authenticated API call."""
    if token is None:
        token = get_token()
    cmd = ["curl", "-s"]
    if method == "POST":
        cmd += ["-X", "POST"]
    elif method == "DELETE":
        cmd += ["-X", "DELETE"]
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
    result = api_call("POST", url, {"requests": requests}, token)
    if "error" in result:
        msg = result["error"].get("message", "")
        print(f"  BATCH ERROR: {msg[:300]}")
    return result


# ============================================================
# Shape builders — return individual batchUpdate request dicts
# ============================================================

def shape_request(slide_id, shape_id, shape_type, x, y, w, h):
    """Create a shape on a slide."""
    return {
        "createShape": {
            "objectId": shape_id,
            "shapeType": shape_type,
            "elementProperties": {
                "pageObjectId": slide_id,
                "size": {
                    "width": {"magnitude": w, "unit": "EMU"},
                    "height": {"magnitude": h, "unit": "EMU"},
                },
                "transform": {
                    "scaleX": 1, "scaleY": 1,
                    "translateX": x, "translateY": y,
                    "unit": "EMU",
                },
            },
        }
    }


def style_shape(shape_id, fill_color=None, stroke_color=None, stroke_weight=1.5):
    """Style a shape's background and outline."""
    props = {}
    fields = []
    if fill_color:
        props["shapeBackgroundFill"] = {
            "solidFill": {"color": {"rgbColor": fill_color}}
        }
        fields.append("shapeBackgroundFill")
    if stroke_color:
        props["outline"] = {
            "outlineFill": {
                "solidFill": {"color": {"rgbColor": stroke_color}}
            },
            "weight": {"magnitude": stroke_weight, "unit": "PT"},
        }
        fields.append("outline")
    if not fields:
        return None
    return {
        "updateShapeProperties": {
            "objectId": shape_id,
            "shapeProperties": props,
            "fields": ",".join(fields),
        }
    }


def text_request(shape_id, text):
    """Insert text into a shape."""
    return {
        "insertText": {
            "objectId": shape_id,
            "insertionIndex": 0,
            "text": text,
        }
    }


def text_style(shape_id, font_size=11, bold=False, color=None, font="Barlow",
               start=None, end=None, alignment=None):
    """Style text in a shape. Returns list of requests."""
    reqs = []
    style = {
        "fontSize": {"magnitude": font_size, "unit": "PT"},
        "fontFamily": font,
        "bold": bold,
    }
    field_list = ["fontSize", "fontFamily", "bold"]
    if color:
        style["foregroundColor"] = {"opaqueColor": {"rgbColor": color}}
        field_list.append("foregroundColor")

    text_range = {"type": "ALL"}
    if start is not None and end is not None:
        text_range = {"type": "FIXED_RANGE", "startIndex": start, "endIndex": end}

    reqs.append({
        "updateTextStyle": {
            "objectId": shape_id,
            "textRange": text_range,
            "style": style,
            "fields": ",".join(field_list),
        }
    })

    if alignment:
        reqs.append({
            "updateParagraphStyle": {
                "objectId": shape_id,
                "textRange": text_range,
                "style": {"alignment": alignment},
                "fields": "alignment",
            }
        })

    return reqs


def line_request(slide_id, line_id, x, y, w, h, category="STRAIGHT"):
    """Create a line/connector."""
    return {
        "createLine": {
            "objectId": line_id,
            "lineCategory": category,
            "elementProperties": {
                "pageObjectId": slide_id,
                "size": {
                    "width": {"magnitude": abs(w), "unit": "EMU"},
                    "height": {"magnitude": abs(h), "unit": "EMU"},
                },
                "transform": {
                    "scaleX": 1 if w >= 0 else -1,
                    "scaleY": 1 if h >= 0 else -1,
                    "translateX": x,
                    "translateY": y,
                    "unit": "EMU",
                },
            },
        }
    }


def style_line(line_id, color=None, weight=2, dash="SOLID", end_arrow="OPEN_ARROW", start_arrow="NONE"):
    """Style a line."""
    props = {
        "weight": {"magnitude": weight, "unit": "PT"},
        "dashStyle": dash,
        "endArrow": end_arrow,
        "startArrow": start_arrow,
    }
    fields = ["weight", "dashStyle", "endArrow", "startArrow"]
    if color:
        props["lineFill"] = {
            "solidFill": {"color": {"rgbColor": color}}
        }
        fields.append("lineFill")
    return {
        "updateLineProperties": {
            "objectId": line_id,
            "lineProperties": props,
            "fields": ",".join(fields),
        }
    }


def image_request(slide_id, img_id, url, x, y, w, h):
    """Create an image on a slide."""
    return {
        "createImage": {
            "objectId": img_id,
            "url": url,
            "elementProperties": {
                "pageObjectId": slide_id,
                "size": {
                    "width": {"magnitude": w, "unit": "EMU"},
                    "height": {"magnitude": h, "unit": "EMU"},
                },
                "transform": {
                    "scaleX": 1, "scaleY": 1,
                    "translateX": x, "translateY": y,
                    "unit": "EMU",
                },
            },
        }
    }


# ============================================================
# High-level diagram element builders
# ============================================================

def make_box(slide_id, x, y, w, h, label, fill_key, stroke_key,
             font_size=10, bold=False, text_color_key="text_dark",
             icon_url=None, icon_size=320000, shape_type="ROUND_RECTANGLE"):
    """Create a styled box with text and optional icon. Returns (requests_list, shape_id)."""
    sid = uid("box")
    reqs = [
        shape_request(slide_id, sid, shape_type, x, y, w, h),
        style_shape(sid, COLORS.get(fill_key), COLORS.get(stroke_key)),
        text_request(sid, label),
    ]
    reqs.extend(text_style(sid, font_size=font_size, bold=bold,
                           color=COLORS.get(text_color_key), alignment="CENTER"))

    if icon_url:
        icon_id = uid("ico")
        # Place icon at top-right of box
        ix = x + w - icon_size - 40000
        iy = y + 40000
        reqs.append(image_request(slide_id, icon_id, icon_url, ix, iy, icon_size, icon_size))

    return reqs, sid


def make_swimlane(slide_id, x, y, w, h, title, fill_key="lane_fill",
                  stroke_key="lane_stroke", title_color_key="text_dark"):
    """Create a swimlane container (background rect + title label). Returns (requests_list, lane_id)."""
    lane_id = uid("lane")
    title_id = uid("ltit")

    reqs = [
        # Background rectangle
        shape_request(slide_id, lane_id, "RECTANGLE", x, y, w, h),
        style_shape(lane_id, COLORS.get(fill_key), COLORS.get(stroke_key), stroke_weight=1.0),
        # Title bar at top
        shape_request(slide_id, title_id, "TEXT_BOX", x, y, w, 340000),
        style_shape(title_id, COLORS.get("dark_bg"), None, stroke_weight=0),
        text_request(title_id, title),
    ]
    reqs.extend(text_style(title_id, font_size=10, bold=True,
                           color=COLORS["text_white"], alignment="CENTER"))

    return reqs, lane_id


def make_arrow(slide_id, x1, y1, x2, y2, color_key="arrow_gray", weight=1.5,
               dash="SOLID", label=None):
    """Create a styled arrow line, optionally with a label. Returns requests list."""
    lid = uid("arr")
    reqs = [
        line_request(slide_id, lid, x1, y1, x2 - x1, y2 - y1),
        style_line(lid, COLORS.get(color_key), weight=weight, dash=dash),
    ]
    if label:
        # Place label text box near midpoint
        mid_x = (x1 + x2) // 2 - 400000
        mid_y = min(y1, y2) - 200000
        lbl_id = uid("albl")
        reqs.append(shape_request(slide_id, lbl_id, "TEXT_BOX", mid_x, mid_y, 800000, 200000))
        reqs.append(text_request(lbl_id, label))
        reqs.extend(text_style(lbl_id, font_size=7, bold=False,
                               color=COLORS.get(color_key), alignment="CENTER"))
    return reqs


def make_title_bar(slide_id, title, subtitle=None):
    """Create a title text box at top of slide. Returns requests list."""
    tid = uid("title")
    reqs = [
        shape_request(slide_id, tid, "TEXT_BOX", 350000, 180000, 11000000, 500000),
        text_request(tid, title),
    ]
    reqs.extend(text_style(tid, font_size=28, bold=True, color=COLORS["text_dark"]))

    if subtitle:
        stid = uid("stit")
        reqs.append(shape_request(slide_id, stid, "TEXT_BOX", 350000, 680000, 11000000, 300000))
        reqs.append(text_request(stid, subtitle))
        reqs.extend(text_style(stid, font_size=12, bold=False, color=COLORS["arrow_gray"]))

    return reqs
