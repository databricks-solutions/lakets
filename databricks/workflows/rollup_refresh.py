"""
LakeTS RollUp Refresh Job
Refreshes all RollUps (incremental where configured).

Schedule: Every 15 minutes (configurable per RollUp via refresh_lag).
"""
import logging
import sys

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
    import os

    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    run(instance)
