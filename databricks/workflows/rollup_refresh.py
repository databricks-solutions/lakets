"""
LakeTS RollUp Refresh Job
Refreshes all RollUps in dependency (DAG) order via refresh_rollup_cascade(),
so a parent RollUp always reads freshly-refreshed children within one run.

Schedule: configurable; each RollUp self-gates on its refresh_lag.
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


def run(project_name: str) -> int:
    """Refresh all RollUps in DAG order. Each RollUp self-gates on refresh_lag,
    so children are refreshed before the parents that read them."""
    with lakebase_cursor(project_name) as cur:
        failures = []
        try:
            results = fetch_all(cur, """
                SELECT rollup_name, refreshed, refresh_ms
                FROM lakets.refresh_rollup_cascade()
            """)
        except Exception as e:
            # Whole-cascade failure (e.g. a broken RollUp query). Surface it.
            failures.append("refresh_rollup_cascade")
            logger.error("Cascade refresh failed: %s", e)
            raise

        refreshed = sum(1 for r in results if r["refreshed"])
        skipped = len(results) - refreshed
        for r in results:
            if r["refreshed"]:
                logger.info("Refreshed: %s (%.1f ms)", r["rollup_name"], r["refresh_ms"] or 0.0)
            else:
                logger.info("Skipped (refresh_lag): %s", r["rollup_name"])

        logger.info("Refreshed %d, skipped %d / %d total", refreshed, skipped, len(results))
        if failures:
            logger.error("Failed refreshes: %s", ", ".join(failures))
        return refreshed


if __name__ == "__main__":
    project = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_PROJECT"]
    run(project)
