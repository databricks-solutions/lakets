"""
LakeTS Partition Manager Job

Pre-creates future Lakebase partitions for every registered ChronoTable so
inserts never hit a missing partition. Calls lakets._ensure_partitions per
ChronoTable.

Schedule: every 6 hours; tune to the smallest chunk_interval in use.

Pass the Lakebase project name as the first job parameter (sys.argv[1]) or set
LAKETS_PROJECT.
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


def run(project_name: str):
    """Pre-create future partitions for every registered ChronoTable.

    Returns the total number of partitions created across all ChronoTables.
    """
    with lakebase_cursor(project_name) as cur:
        chronotables = fetch_all(cur, """
            SELECT id, schema_name, table_name, chunk_interval
            FROM lakets._chronotable_registry
        """)
        logger.info("Found %d chronotable(s)", len(chronotables))

        total_created = 0
        for ht in chronotables:
            cur.execute(
                "SELECT lakets._ensure_partitions(p_chronotable_id := %s)",
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
    project = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_PROJECT"]
    run(project)
