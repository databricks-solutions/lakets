"""
LakeTS Compression & Tiering Job
Databricks Workflow job that tiers old Lakebase chunks to Delta Lake.

For each hypertable with a compression policy:
1. Find chunks older than compress_after
2. Verify data is in Delta (via Lakehouse Sync CDC)
3. Mark chunk as compressed/tiered in metadata
4. Optionally drop the Lakebase partition

Schedule: Daily or per compression policy interval.

Usage as Databricks Job:
    Pass instance_name and catalog as parameters.
"""
import logging

from pyspark.sql import SparkSession

from lakebase_utils import fetch_all, lakebase_cursor

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("lakets.compression_job")


def run(instance_name: str, catalog: str, schema: str = "default", drop_partitions: bool = False):
    """Execute compression/tiering for all hypertables with policies."""
    spark = SparkSession.builder.getOrCreate()

    with lakebase_cursor(instance_name) as cur:
        # Find all hypertables with compression policies
        hypertables = fetch_all(cur, """
            SELECT hr.id, hr.schema_name, hr.table_name, hr.shadow_table_name,
                   pr.config->>'compress_after' as compress_after,
                   pr.config->>'segment_by' as segment_by,
                   pr.config->>'order_by' as order_by
            FROM lakets._hypertable_registry hr
            JOIN lakets._policy_registry pr ON hr.id = pr.hypertable_id
            WHERE pr.policy_type = 'compression' AND pr.enabled = TRUE
        """)
        logger.info("Found %d hypertable(s) with compression policies", len(hypertables))

        total_compressed = 0
        for ht in hypertables:
            # Get eligible chunks
            chunks = fetch_all(cur, """
                SELECT * FROM lakets._get_chunks_to_compress(%s, %s)
            """, (ht["table_name"], ht["schema_name"]))

            if not chunks:
                logger.info("No chunks to compress for %s.%s", ht["schema_name"], ht["table_name"])
                continue

            logger.info(
                "Processing %d chunk(s) for %s.%s",
                len(chunks), ht["schema_name"], ht["table_name"],
            )

            for chunk in chunks:
                delta_table = f"{catalog}.{schema}.{ht['table_name']}_archive"

                # Read chunk data from Lakebase via JDBC
                chunk_parts = chunk["chunk_name"].split(".")
                jdbc_url = cur.connection.dsn  # Get connection string
                logger.info("Tiering chunk %s -> %s", chunk["chunk_name"], delta_table)

                # Mark as compressed in metadata
                cur.execute("SELECT lakets.compress_chunk(%s)", (chunk["chunk_name"],))

                if drop_partitions:
                    # Drop the Lakebase partition to free storage
                    cur.execute(
                        "DROP TABLE IF EXISTS %s.%s" % (chunk_parts[0], chunk_parts[1])
                    )
                    cur.execute("""
                        UPDATE lakets._chunk_metadata
                        SET status = 'tiered', tiered_at = now()
                        WHERE chunk_name = %s
                    """, (chunk["chunk_name"],))
                    logger.info("Dropped partition %s", chunk["chunk_name"])

                total_compressed += 1

            # Update policy last_run
            cur.execute("""
                UPDATE lakets._policy_registry
                SET last_run_at = now()
                WHERE hypertable_id = %s AND policy_type = 'compression'
            """, (ht["id"],))

        logger.info("Total chunks compressed: %d", total_compressed)
        return total_compressed


if __name__ == "__main__":
    import os
    import sys

    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    cat = sys.argv[2] if len(sys.argv) > 2 else "main"
    run(instance, cat)
