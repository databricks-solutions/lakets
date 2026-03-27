"""
LakeTS Cold-Tier RollUp Re-Aggregation Job

Reads cold-tier invalidation entries from _rollup_invalidation_log,
re-aggregates from Delta Lake via Databricks SQL, and writes results
back to the Lakebase RollUp Table.

M26 enhancements:
- cold_query_text override for complex multi-table JOINs
- bucket_column support (no longer hardcoded to 'bucket')
- Serverless warehouse auto-start

Schedule: On-demand, or after cold-tier ETL corrections.
"""
import logging
import sys
import time

from databricks.sdk import WorkspaceClient

from lakebase_utils import fetch_all, lakebase_cursor

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("lakets.cold_rollup_refresh")


def _resolve_cold_query(entry: dict, delta_table: str) -> str:
    """
    Resolve the query to use for cold-tier re-aggregation.

    Priority:
    1. cold_query_text (explicit override for complex queries)
    2. String substitution of source table -> Delta table in query_text
    """
    if entry.get("cold_query_text"):
        return entry["cold_query_text"]

    cold_query = entry["query_text"].replace(
        f"{entry['source_schema']}.{entry['source_table']}",
        delta_table,
    )
    cold_query = cold_query.replace(entry["source_table"], delta_table)
    return cold_query


def run(instance_name: str, catalog: str = "main", schema: str = "lakets_sync"):
    """Re-aggregate cold-tier dirty buckets from Delta Lake."""
    w = WorkspaceClient()

    with lakebase_cursor(instance_name) as cur:
        cold_entries = fetch_all(cur, """
            SELECT r.id AS rollup_id, r.name, r.rollup_table, r.bucket_interval,
                   r.query_text,
                   r.cold_query_text,
                   COALESCE(r.bucket_column, 'bucket') AS bucket_column,
                   cr.table_name AS source_table, cr.schema_name AS source_schema,
                   array_agg(DISTINCT il.bucket_start ORDER BY il.bucket_start) AS dirty_buckets
            FROM lakets._rollup_invalidation_log il
            JOIN lakets._rollup_registry r ON il.rollup_id = r.id
            JOIN lakets._chronotable_registry cr ON r.source_chronotable_id = cr.id
            WHERE il.tier = 'cold'
            GROUP BY r.id, r.name, r.rollup_table, r.bucket_interval, r.query_text,
                     r.cold_query_text, r.bucket_column,
                     cr.table_name, cr.schema_name
        """)

        if not cold_entries:
            logger.info("No cold-tier invalidations pending")
            return 0

        warehouse_id = _get_warehouse_id(w)
        refreshed = 0

        for entry in cold_entries:
            delta_table = f"{catalog}.{schema}.{entry['source_table']}"
            dirty_buckets = entry["dirty_buckets"]
            bucket_col = entry.get("bucket_column", "bucket")

            logger.info(
                "Re-aggregating %s: %d cold buckets from %s",
                entry["name"], len(dirty_buckets), delta_table,
            )

            cold_query = _resolve_cold_query(entry, delta_table)
            bucket_list = ", ".join(f"TIMESTAMP '{b}'" for b in dirty_buckets)

            try:
                result = w.statement_execution.execute_statement(
                    warehouse_id=warehouse_id,
                    statement=(
                        f"SELECT * FROM ({cold_query}) _q "
                        f"WHERE _q.{bucket_col} IN ({bucket_list})"
                    ),
                    wait_timeout="120s",
                )

                if result.result and result.result.data_array:
                    columns = [col.name for col in result.manifest.schema.columns]

                    # Delete old rows for dirty buckets
                    for bucket in dirty_buckets:
                        cur.execute(
                            f"DELETE FROM public.{entry['rollup_table']} "
                            f"WHERE {bucket_col} = %s",
                            (bucket,),
                        )

                    # Insert re-aggregated rows
                    placeholders = ", ".join(["%s"] * len(columns))
                    col_list = ", ".join(columns)
                    for row in result.result.data_array:
                        cur.execute(
                            f"INSERT INTO public.{entry['rollup_table']} ({col_list}) "
                            f"VALUES ({placeholders})",
                            row,
                        )

                    refreshed += 1
                    logger.info(
                        "Re-aggregated: %s (%d buckets, %d rows)",
                        entry["name"], len(dirty_buckets), len(result.result.data_array),
                    )
                else:
                    logger.warning(
                        "No data returned from Delta for %s (%d buckets)",
                        entry["name"], len(dirty_buckets),
                    )

                # Clear processed cold-tier entries
                cur.execute(
                    "DELETE FROM lakets._rollup_invalidation_log "
                    "WHERE rollup_id = %s AND tier = 'cold'",
                    (entry["rollup_id"],),
                )

            except Exception as e:
                logger.error("Failed to re-aggregate %s: %s", entry["name"], e)

        logger.info("Cold-tier refresh complete: %d RollUps processed", refreshed)
        return refreshed


def _get_warehouse_id(w: WorkspaceClient) -> str:
    """Get the first available SQL warehouse. Auto-starts stopped serverless warehouses."""
    warehouses = list(w.warehouses.list())

    # Prefer already-running warehouses
    for wh in warehouses:
        if wh.state and wh.state.value == "RUNNING":
            return wh.id

    # Try to start a stopped serverless warehouse
    for wh in warehouses:
        if wh.state and wh.state.value == "STOPPED":
            logger.info("Starting stopped warehouse %s (%s)", wh.name, wh.id)
            w.warehouses.start(wh.id)

            for _ in range(24):  # 120s timeout
                time.sleep(5)
                status = w.warehouses.get(wh.id)
                if status.state and status.state.value == "RUNNING":
                    logger.info("Warehouse %s is now running", wh.name)
                    return wh.id

            logger.warning("Warehouse %s did not start within 120s", wh.name)

    raise RuntimeError(
        "No SQL warehouse available. Cold-tier re-aggregation requires a running warehouse."
    )


if __name__ == "__main__":
    import os

    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    cat = sys.argv[2] if len(sys.argv) > 2 else "main"
    sch = sys.argv[3] if len(sys.argv) > 3 else "lakets_sync"
    run(instance, cat, sch)
