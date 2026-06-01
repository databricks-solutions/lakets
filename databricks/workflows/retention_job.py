"""
LakeTS Retention Job
Databricks Workflow job that enforces retention policies.

For each chronotable with a retention or tiered_retention policy:
1. Drop Lakebase partitions older than drop_after
2. For tiered_retention: also vacuum Delta tables beyond drop_after

Schedule: Daily.
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
logger = logging.getLogger("lakets.retention_job")


def run(project_name: str):
    """Execute retention for all chronotables with policies."""
    with lakebase_cursor(project_name) as cur:
        chronotables = fetch_all(cur, """
            SELECT hr.schema_name, hr.table_name,
                   pr.policy_type,
                   pr.config->>'drop_after' as drop_after,
                   pr.config->>'tier_after' as tier_after
            FROM lakets._chronotable_registry hr
            JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
            WHERE pr.policy_type IN ('retention', 'tiered_retention')
              AND pr.enabled = TRUE
        """)
        logger.info("Found %d chronotable(s) with retention policies", len(chronotables))

        total_dropped = 0
        for ht in chronotables:
            cur.execute(
                "SELECT lakets.execute_retention(%s, %s)",
                (ht["table_name"], ht["schema_name"]),
            )
            dropped = cur.fetchone()[0]
            total_dropped += dropped
            logger.info(
                "%s.%s: dropped %d chunk(s) (policy=%s, drop_after=%s)",
                ht["schema_name"], ht["table_name"],
                dropped, ht["policy_type"], ht["drop_after"],
            )

        logger.info("Total chunks dropped: %d", total_dropped)
        return total_dropped


if __name__ == "__main__":
    project = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_PROJECT"]
    run(project)
