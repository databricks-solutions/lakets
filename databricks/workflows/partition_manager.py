"""
LakeTS Partition Manager Job
Databricks Workflow job that pre-creates future partitions for all hypertables.

Schedule: Every 6 hours (or customize per chunk_interval).

Usage as Databricks Job:
    Pass the Lakebase instance name as the first job parameter (sys.argv[1]),
    or set the LAKETS_INSTANCE environment variable.
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
logger = logging.getLogger("lakets.partition_manager")


def run(instance_name: str):
    """Pre-create future partitions for all registered hypertables."""
    with lakebase_cursor(instance_name) as cur:
        hypertables = fetch_all(cur, """
            SELECT id, schema_name, table_name, chunk_interval
            FROM lakets._hypertable_registry
        """)
        logger.info("Found %d hypertable(s)", len(hypertables))

        total_created = 0
        for ht in hypertables:
            cur.execute(
                "SELECT lakets._ensure_partitions(p_hypertable_id := %s)",
                (ht["id"],),
            )
            created = cur.fetchone()[0]
            total_created += created
            if created > 0:
                logger.info(
                    "Created %d partition(s) for %s.%s",
                    created, ht["schema_name"], ht["table_name"],
                )

        logger.info("Total partitions created: %d", total_created)
        return total_created


if __name__ == "__main__":
    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    run(instance)
