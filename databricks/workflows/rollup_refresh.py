"""
LakeTS RollUp Refresh Job
Refreshes all RollUps (incremental where configured).

Schedule: Every 15 minutes (configurable per RollUp via refresh_lag).
"""
import logging
import os
import sys

# Ensure sibling modules (lakebase_utils) are importable when run as a
# spark_python_task. On serverless the file runs via exec() with no __file__
# defined, so fall back to the working directory (Databricks sets it to the
# file's workspace folder).
try:
    _here = os.path.dirname(os.path.abspath(__file__))
except NameError:
    _here = os.getcwd()
if _here not in sys.path:
    sys.path.insert(0, _here)

from lakebase_utils import fetch_all, lakebase_cursor

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("lakets.rollup_refresh")


def run(instance_name: str):
    """Refresh all RollUps."""
    with lakebase_cursor(instance_name) as cur:
        rollups = fetch_all(cur, """
            SELECT name, refresh_lag, last_refreshed_at, watermark
            FROM lakets._rollup_registry
            ORDER BY name
        """)
        logger.info("Found %d RollUp(s)", len(rollups))

        refreshed = 0
        skipped = 0
        failures = []
        for rollup in rollups:
            try:
                cur.execute(
                    "SELECT lakets.refresh_rollup(%s)",
                    (rollup["name"],),
                )
                result = cur.fetchone()[0]
                if result:
                    refreshed += 1
                    logger.info("Refreshed: %s", rollup["name"])
                else:
                    skipped += 1
                    logger.info("Skipped (refresh_lag): %s", rollup["name"])
            except Exception as e:
                logger.error("Failed to refresh %s: %s", rollup["name"], e)
                failures.append(rollup["name"])

        logger.info("Refreshed %d, skipped %d / %d total", refreshed, skipped, len(rollups))
        if failures:
            logger.error("Failed refreshes: %s", ", ".join(failures))
        return refreshed


if __name__ == "__main__":
    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    run(instance)
