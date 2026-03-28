"""
LakeTS RollUp Export Pipeline (Module 28)

Reads export-enabled RollUp Table rows from Lakebase and writes them
to Delta Lake for Spark/ML/BI consumption.

Supports two modes:
- full: OVERWRITE the Delta table with the entire RollUp Table
- incremental: INSERT only rows created since last export (based on bucket column)

Schedule: After rollup_refresh.py, or on a separate cadence.
"""
import logging
import re
import sys

from databricks.sdk import WorkspaceClient
from psycopg2 import sql

from lakebase_utils import fetch_all, lakebase_cursor

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("lakets.rollup_export")


def run(instance_name: str, rollup_name: str | None = None):
    """Export RollUp Table rows to Delta Lake."""
    w = WorkspaceClient()
    spark = _get_spark()

    with lakebase_cursor(instance_name) as cur:
        if rollup_name:
            exports = fetch_all(cur, """
                SELECT name, rollup_table, export_delta_table, export_mode,
                       COALESCE(bucket_column, 'bucket') AS bucket_column,
                       last_exported_at, watermark
                FROM lakets._rollup_registry
                WHERE export_enabled = TRUE AND name = %s
                ORDER BY name
            """, (rollup_name,))
        else:
            exports = fetch_all(cur, """
                SELECT name, rollup_table, export_delta_table, export_mode,
                       COALESCE(bucket_column, 'bucket') AS bucket_column,
                       last_exported_at, watermark
                FROM lakets._rollup_registry
                WHERE export_enabled = TRUE
                ORDER BY name
            """)

        if not exports:
            logger.info("No export-enabled RollUps found")
            return 0

        logger.info("Found %d export-enabled RollUp(s)", len(exports))
        exported_count = 0

        failures = []
        for entry in exports:
            name = entry["name"]
            rollup_table = entry["rollup_table"]
            delta_table = entry["export_delta_table"]
            mode = entry["export_mode"]
            bucket_col = entry["bucket_column"]
            last_exported = entry["last_exported_at"]

            # Validate identifiers to prevent SQL injection
            _validate_identifier(rollup_table)
            _validate_identifier(bucket_col)

            logger.info(
                "Exporting %s -> %s (mode=%s)", name, delta_table, mode,
            )

            try:
                if mode == "full":
                    rows = _export_full(cur, spark, rollup_table, delta_table)
                else:
                    rows = _export_incremental(
                        cur, spark, rollup_table, delta_table,
                        bucket_col, last_exported,
                    )

                # Update last_exported_at
                cur.execute(
                    "UPDATE lakets._rollup_registry SET last_exported_at = now() "
                    "WHERE name = %s",
                    (name,),
                )

                exported_count += 1
                logger.info("Exported %s: %d rows", name, rows)

            except Exception as e:
                logger.error("Failed to export %s: %s", name, e)
                failures.append(name)

        logger.info("Export complete: %d RollUp(s) processed", exported_count)
        if failures:
            logger.error("Failed exports: %s", ", ".join(failures))
        return exported_count


def _validate_identifier(name: str):
    """Validate that a name is a safe SQL identifier."""
    if not re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', name):
        raise ValueError(f"Invalid SQL identifier: {name!r}")


def _export_full(cur, spark, rollup_table: str, delta_table: str) -> int:
    """Full overwrite export: read entire RollUp Table, write to Delta."""
    query = sql.SQL("SELECT * FROM {}.{}").format(
        sql.Identifier("public"), sql.Identifier(rollup_table)
    )
    rows = fetch_all(cur, query)

    if not rows:
        logger.info("  RollUp table is empty, skipping")
        return 0

    df = spark.createDataFrame(rows)
    df.write.format("delta").mode("overwrite").option(
        "overwriteSchema", "true"
    ).saveAsTable(delta_table)

    return len(rows)


def _export_incremental(
    cur, spark, rollup_table: str, delta_table: str,
    bucket_col: str, last_exported_at: str | None,
) -> int:
    """Incremental export: only rows newer than last_exported_at."""
    if last_exported_at:
        query = sql.SQL("SELECT * FROM {}.{} WHERE {} > %s ORDER BY {}").format(
            sql.Identifier("public"), sql.Identifier(rollup_table),
            sql.Identifier(bucket_col), sql.Identifier(bucket_col),
        )
        rows = fetch_all(cur, query, (last_exported_at,))
    else:
        query = sql.SQL("SELECT * FROM {}.{} ORDER BY {}").format(
            sql.Identifier("public"), sql.Identifier(rollup_table),
            sql.Identifier(bucket_col),
        )
        rows = fetch_all(cur, query)

    if not rows:
        logger.info("  No new rows to export")
        return 0

    df = spark.createDataFrame(rows)
    df.write.format("delta").mode("append").saveAsTable(delta_table)

    return len(rows)


def _get_spark():
    """Get or create SparkSession (available in Databricks runtime)."""
    try:
        from pyspark.sql import SparkSession
        return SparkSession.builder.getOrCreate()
    except ImportError:
        raise RuntimeError(
            "PySpark not available. rollup_export.py must run in a Databricks environment."
        )


if __name__ == "__main__":
    import os

    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    name = sys.argv[2] if len(sys.argv) > 2 else None
    run(instance, name)
