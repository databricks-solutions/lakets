#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# LakeTS Build Script
# Concatenates SQL modules into a single distributable file.
# Usage: ./build.sh
# Output: dist/lakets.sql
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
DIST_DIR="${SCRIPT_DIR}/dist"
VERSION_FILE="${SCRIPT_DIR}/VERSION"

# Read version
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
else
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")
fi

BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Module concatenation order (matches 99_install.sql)
# Modules are numbered sequentially matching installation order
MODULES=(
    "00_version.sql"
    "01_schema.sql"
    "02_chronotable.sql"
    "03_timeseries_functions.sql"
    "04_rollup.sql"
    "05_compression.sql"
    "06_retention.sql"
    "07_monitoring.sql"
    "08_metric_table.sql"
    "09_lvc.sql"
    "10_downsample.sql"
    "11_alerts.sql"
    "12_ingest.sql"
    "13_shadow_sync.sql"
    "14_rollup_optimization.sql"
)

# Validate all modules exist
for module in "${MODULES[@]}"; do
    if [ ! -f "${SQL_DIR}/${module}" ]; then
        echo "ERROR: Module not found: ${SQL_DIR}/${module}" >&2
        exit 1
    fi
done

# Create dist directory
mkdir -p "$DIST_DIR"
OUTPUT="${DIST_DIR}/lakets.sql"

# ------------------------------------------------------------------
# HEADER
# ------------------------------------------------------------------
cat > "$OUTPUT" << EOF
-- =============================================================================
-- LakeTS v${VERSION} — Time Series Toolkit for Databricks Lakebase
--
-- Version:    ${VERSION}
-- Built:      ${BUILD_DATE}
-- Git SHA:    ${GIT_SHA}
--
-- Install:    psql -f lakets.sql
--         or: conn.cursor().execute(open('lakets.sql').read())
--
-- This is a concatenated build. Do not edit — regenerate with: make build
-- =============================================================================

EOF

# ------------------------------------------------------------------
# MODULE CONCATENATION
# ------------------------------------------------------------------
for module in "${MODULES[@]}"; do
    echo "" >> "$OUTPUT"
    echo "-- ######################################################################" >> "$OUTPUT"
    echo "-- ## MODULE: ${module}" >> "$OUTPUT"
    echo "-- ######################################################################" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    cat "${SQL_DIR}/${module}" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
done

# ------------------------------------------------------------------
# FOOTER: Update _version.modules + verification
# ------------------------------------------------------------------
MODULE_LIST=$(printf "'%s'," "${MODULES[@]}" | sed 's/,$//')

cat >> "$OUTPUT" << 'FOOTER_START'

-- ######################################################################
-- ## INSTALLATION VERIFICATION
-- ######################################################################

FOOTER_START

# Write the UPDATE with module list (needs variable expansion)
cat >> "$OUTPUT" << EOF
UPDATE lakets._version
SET modules = ARRAY[${MODULE_LIST}]
WHERE version = '${VERSION}'
  AND installed_at = (
      SELECT MAX(installed_at) FROM lakets._version WHERE version = '${VERSION}'
  );
EOF

# Write the verification block (dollar-quoted, no variable expansion)
cat >> "$OUTPUT" << 'FOOTER_END'

DO $$
DECLARE
    v_func_count  INT;
    v_table_count INT;
    v_version     TEXT;
BEGIN
    SELECT version INTO v_version
    FROM lakets._version ORDER BY installed_at DESC LIMIT 1;

    SELECT count(*) INTO v_func_count
    FROM information_schema.routines WHERE routine_schema = 'lakets';

    SELECT count(*) INTO v_table_count
    FROM information_schema.tables WHERE table_schema = 'lakets';

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'LakeTS v% installed successfully', v_version;
    RAISE NOTICE '  Functions: %', v_func_count;
    RAISE NOTICE '  Tables:    %', v_table_count;
    RAISE NOTICE '===========================================';
END $$;
FOOTER_END

# ------------------------------------------------------------------
# VERSION PLACEHOLDER REPLACEMENT
# ------------------------------------------------------------------
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/__LAKETS_VERSION__/${VERSION}/g" "$OUTPUT"
else
    sed -i "s/__LAKETS_VERSION__/${VERSION}/g" "$OUTPUT"
fi

# ------------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------------
LINE_COUNT=$(wc -l < "$OUTPUT" | tr -d ' ')
echo "Built: ${OUTPUT}"
echo "Version: ${VERSION} (${GIT_SHA})"
echo "Modules: ${#MODULES[@]}"
echo "Lines: ${LINE_COUNT}"
