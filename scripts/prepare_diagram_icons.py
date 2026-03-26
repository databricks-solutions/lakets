#!/usr/bin/env python3
"""Extract SVG icons from draw.io packs, convert to PNG, upload to Google Drive."""

import json
import os
import subprocess
import sys
from urllib.parse import unquote

ICONS_DIR = os.path.expanduser(
    "~/.claude/plugins/cache/fe-vibe/fe-specialized-agents/1.0.4/skills/drawio-diagram/icons/packs"
)
OUTPUT_DIR = os.path.expanduser(
    "~/Documents/Claude Projects/Lakebase/timeseries/diagrams/icons"
)
QUOTA_PROJECT = "gcp-sandbox-field-eng"

# Icons to extract: (name, pack_file, key_in_pack)
ICONS_NEEDED = [
    ("postgresql", "databases.json", "postgresql"),
    ("databricks", "databricks.json", "databricks"),
    ("delta_lake", "databricks.json", "delta_lake"),
    ("spark", "databricks.json", "spark"),
    ("mlflow", "databricks.json", "mlflow"),
    ("unity_catalog", "databricks.json", "unity_catalog"),
    ("workflows", "databricks.json", "workflows_2"),
    ("prometheus", "monitoring.json", "prometheus"),
    ("grafana", "monitoring.json", "grafana"),
    ("amazon_s3", "aws.json", "amazon_s3"),
    ("kafka", "streaming.json", "kafka"),
    ("python", "languages.json", "python"),
]


def get_token():
    r = subprocess.run(
        ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
         "auth", "application-default", "print-access-token"],
        capture_output=True, text=True,
    )
    return r.stdout.strip()


def extract_svg(pack_file, icon_key):
    """Extract SVG content from a draw.io icon pack."""
    pack_path = os.path.join(ICONS_DIR, pack_file)
    if not os.path.exists(pack_path):
        print(f"  WARNING: Pack {pack_file} not found")
        return None

    with open(pack_path) as f:
        pack = json.load(f)

    data_uri = pack.get(icon_key, {}).get("data_uri", "")
    if not data_uri:
        # Try without nested structure
        if isinstance(pack.get(icon_key), str):
            data_uri = pack[icon_key]

    if not data_uri:
        print(f"  WARNING: Icon {icon_key} not found in {pack_file}")
        return None

    # data_uri format: data:image/svg+xml,%3Csvg...
    if data_uri.startswith("data:image/svg+xml,"):
        svg_encoded = data_uri[len("data:image/svg+xml,"):]
        svg_content = unquote(svg_encoded)
        return svg_content
    elif data_uri.startswith("data:image/svg+xml;utf8,"):
        svg_encoded = data_uri[len("data:image/svg+xml;utf8,"):]
        svg_content = unquote(svg_encoded)
        return svg_content

    print(f"  WARNING: Unexpected data_uri format for {icon_key}")
    return None


def svg_to_png(svg_content, output_path, size=128):
    """Convert SVG to PNG using cairosvg or rsvg-convert."""
    svg_path = output_path.replace(".png", ".svg")
    with open(svg_path, "w") as f:
        f.write(svg_content)

    # Try cairosvg first (Python library)
    try:
        import cairosvg
        cairosvg.svg2png(
            bytestring=svg_content.encode("utf-8"),
            write_to=output_path,
            output_width=size,
            output_height=size,
        )
        return True
    except ImportError:
        pass

    # Try rsvg-convert (CLI)
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size),
             "-o", output_path, svg_path],
            check=True, capture_output=True,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    # Try Inkscape
    try:
        subprocess.run(
            ["inkscape", svg_path, f"--export-filename={output_path}",
             f"--export-width={size}", f"--export-height={size}"],
            check=True, capture_output=True,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    # Try sips (macOS built-in) - convert SVG file
    try:
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", str(size), str(size),
             svg_path, "--out", output_path],
            check=True, capture_output=True,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    print(f"  WARNING: No SVG converter found. Keeping SVG for {output_path}")
    return False


def upload_to_drive(local_path, token):
    """Upload file to Google Drive and make publicly accessible. Returns file_id."""
    filename = os.path.basename(local_path)
    mime = "image/png" if local_path.endswith(".png") else "image/svg+xml"

    result = subprocess.run([
        "curl", "-s", "-X", "POST",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-F", f'metadata={{"name": "icon_{filename}", "mimeType": "{mime}"}};type=application/json',
        "-F", f"file=@{local_path};type={mime}",
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
    ], capture_output=True, text=True)

    file_data = json.loads(result.stdout)
    file_id = file_data.get("id")
    if not file_id:
        print(f"  ERROR uploading {filename}: {result.stdout[:200]}")
        return None

    # Make publicly accessible (required for Slides API createImage)
    subprocess.run([
        "curl", "-s", "-X", "POST",
        f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"x-goog-user-project: {QUOTA_PROJECT}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"role": "reader", "type": "anyone"}),
    ], capture_output=True, text=True)

    return file_id


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 50)
    print("Preparing diagram icons")
    print("=" * 50)

    token = get_token()
    icon_urls = {}

    for name, pack_file, key in ICONS_NEEDED:
        print(f"\n  [{name}] Extracting from {pack_file}...")
        svg = extract_svg(pack_file, key)
        if not svg:
            continue

        # Save SVG
        svg_path = os.path.join(OUTPUT_DIR, f"{name}.svg")
        with open(svg_path, "w") as f:
            f.write(svg)

        # Convert to PNG
        png_path = os.path.join(OUTPUT_DIR, f"{name}.png")
        converted = svg_to_png(svg, png_path, size=128)

        # Upload whichever format we have
        upload_path = png_path if converted and os.path.exists(png_path) else svg_path
        file_id = upload_to_drive(upload_path, token)
        if file_id:
            url = f"https://drive.google.com/uc?id={file_id}&export=download"
            icon_urls[name] = url
            print(f"  [{name}] Uploaded -> {file_id}")

    # Save URL mapping
    mapping_path = os.path.join(OUTPUT_DIR, "icon_urls.json")
    with open(mapping_path, "w") as f:
        json.dump(icon_urls, f, indent=2)

    print(f"\n{'=' * 50}")
    print(f"Done! {len(icon_urls)} icons uploaded.")
    print(f"URL mapping saved to: {mapping_path}")
    print(f"{'=' * 50}")

    return icon_urls


if __name__ == "__main__":
    main()
