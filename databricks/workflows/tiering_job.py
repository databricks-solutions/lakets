"""
LakeTS Tiering Job

Drops cold ChronoTable partitions to reclaim Lakebase storage. The data is
already durable in the Unity Catalog Managed Table via Lakebase CDF; this job
only evicts partitions that lakets.tier_chunk confirms are safe to drop (the
table's CDF shadow is STREAMING and has flushed past the WAL head). The drop
and the metadata transition happen inside tier_chunk, so this job is pure
Lakebase SQL — no Spark.

Schedule: Daily or per tiering policy interval.

Usage as Databricks Job:
    Pass project_name as a parameter.
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
logger = logging.getLogger("lakets.tiering_job")


def run(project_name: str) -> int:
    """Evict eligible, CDF-durable chunks for all tables with a tiering policy.

    Returns the number of partitions actually dropped this run.
    """
    total_tiered = 0
    deferred = 0
    with lakebase_cursor(project_name) as cur:
        tables = fetch_all(cur, """
            SELECT hr.id, hr.schema_name, hr.table_name
            FROM lakets._chronotable_registry hr
            JOIN lakets._policy_registry pr ON hr.id = pr.chronotable_id
            WHERE pr.policy_type = 'tiering' AND pr.enabled = TRUE
        """)
        logger.info("Found %d table(s) with tiering policies", len(tables))

        for t in tables:
            chunks = fetch_all(cur, """
                SELECT * FROM lakets._get_chunks_to_tier(%s, %s)
            """, (t["table_name"], t["schema_name"]))

            if not chunks:
                logger.info(
                    "No eligible chunks for %s.%s (not aged out, or CDF not streaming)",
                    t["schema_name"], t["table_name"],
                )
                continue

            logger.info(
                "Evaluating %d chunk(s) for %s.%s",
                len(chunks), t["schema_name"], t["table_name"],
            )

            for chunk in chunks:
                cur.execute("SELECT lakets.tier_chunk(%s)", (chunk["chunk_name"],))
                dropped = cur.fetchone()[0]  # raw cursor returns tuples (see fetch_all)
                if dropped:
                    total_tiered += 1
                    logger.info("Tiered (dropped) partition %s", chunk["chunk_name"])
                else:
                    deferred += 1
                    logger.info("Deferred %s — CDF not caught up to WAL head", chunk["chunk_name"])

            cur.execute("""
                UPDATE lakets._policy_registry SET last_run_at = now()
                WHERE chronotable_id = %s AND policy_type = 'tiering'
            """, (t["id"],))

        logger.info("Tiering complete: %d dropped, %d deferred", total_tiered, deferred)
        return total_tiered


if __name__ == "__main__":
    project = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_PROJECT"]
    run(project)
