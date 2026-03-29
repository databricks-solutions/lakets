"""
LakeTS Unity Catalog Registration Job

Runs after rollup_export.py. For each export-enabled RollUp:
  1. Ensures the Delta table exists in Unity Catalog (CREATE TABLE IF NOT EXISTS).
  2. Applies UC tags via the Databricks REST API.
  3. Records the registration and tags in lakets._uc_registry via SQL functions.

Schedule: Daily after rollup_export (e.g. 04:30 AM), or triggered by rollup_export.
"""
import json
import logging
import os
import re
import sys
import time
from typing import Any

import requests
from databricks.sdk import WorkspaceClient

from lakebase_utils import fetch_all, lakebase_cursor

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("lakets.uc_registration")


def run(
    instance_name: str,
    uc_catalog: str,
    uc_schema: str,
    rollup_name: str | None = None,
    extra_tags: dict[str, str] | None = None,
) -> int:
    """Register and tag all export-enabled RollUps in Unity Catalog.

    Args:
        instance_name: Lakebase instance name (e.g. "lakets-timeseries").
        uc_catalog:    Target UC catalog (e.g. "main").
        uc_schema:     Target UC schema (e.g. "lakets_exports").
        rollup_name:   Optional; process only this RollUp.
        extra_tags:    Optional; additional key/value tags to apply.

    Returns:
        Number of RollUps successfully registered.
    """
    w = WorkspaceClient()
    host = _get_host(w)

    with lakebase_cursor(instance_name) as cur:
        exports = _get_export_enabled_rollups(cur, rollup_name)
        if not exports:
            logger.info("No export-enabled RollUps found")
            return 0

        logger.info("Processing %d RollUp(s) for UC registration", len(exports))
        registered = 0
        failures = []

        for entry in exports:
            name = entry["name"]
            delta_table = entry["export_delta_table"]

            try:
                # 1. Ensure the UC table exists (external table over the Delta path)
                _ensure_uc_table(w, uc_catalog, uc_schema, delta_table)

                # 2. Record registration in Lakebase
                cur.execute(
                    "SELECT lakets.register_uc_table(%s, %s, %s)",
                    (name, uc_catalog, uc_schema),
                )
                logger.info("Registered %s -> %s.%s", name, uc_catalog, uc_schema)

                # 3. Build tag payload and apply via REST API
                tags = _build_tags(name, extra_tags)
                uc_table_name = _derive_uc_table_name(delta_table, name)
                full_uc_name = f"{uc_catalog}.{uc_schema}.{uc_table_name}"
                _apply_uc_tags(host, w.config.token, full_uc_name, tags)

                # 4. Persist tag record in Lakebase
                cur.execute(
                    "SELECT lakets.tag_uc_table(%s, %s::jsonb)",
                    (name, json.dumps(tags)),
                )
                logger.info("Tagged %s with %d tag(s)", name, len(tags))

                registered += 1

            except Exception as exc:
                logger.error("Failed to process RollUp %s: %s", name, exc)
                failures.append(name)

        logger.info("UC registration complete: %d registered", registered)
        if failures:
            logger.error("Failed: %s", ", ".join(failures))
        return registered


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _get_export_enabled_rollups(cur: Any, rollup_name: str | None) -> list[dict]:
    """Fetch export-enabled RollUps from Lakebase."""
    if rollup_name:
        return fetch_all(
            cur,
            """
            SELECT name, export_delta_table, export_mode
            FROM lakets._rollup_registry
            WHERE export_enabled = TRUE AND export_delta_table IS NOT NULL AND name = %s
            """,
            (rollup_name,),
        )
    return fetch_all(
        cur,
        """
        SELECT name, export_delta_table, export_mode
        FROM lakets._rollup_registry
        WHERE export_enabled = TRUE AND export_delta_table IS NOT NULL
        ORDER BY name
        """,
    )


def _ensure_uc_table(w: WorkspaceClient, catalog: str, schema: str, delta_table: str) -> None:
    """Create the UC schema and register the Delta table if not already present.

    Uses Databricks SQL statement execution API so no Spark session is required.
    """
    warehouse_id = _get_warehouse_id(w)
    stmts = [
        f"CREATE SCHEMA IF NOT EXISTS `{catalog}`.`{schema}`",
        (
            f"CREATE TABLE IF NOT EXISTS `{delta_table.replace('.', '`.`')}`"
            f" USING DELTA"
        ),
    ]
    for stmt in stmts:
        _run_sql_statement(w, warehouse_id, stmt)


def _apply_uc_tags(host: str, token: str, full_uc_name: str, tags: dict[str, str]) -> None:
    """Apply tags to a UC table via the Databricks Catalog API."""
    parts = full_uc_name.split(".")
    if len(parts) != 3:
        raise ValueError(f"Invalid UC table name: {full_uc_name!r}")
    catalog, schema, table = parts

    url = (
        f"{host}/api/2.1/unity-catalog/tables"
        f"/{catalog}.{schema}.{table}"
    )
    tag_list = [{"key": k, "value": v} for k, v in tags.items()]
    payload = {"tags": tag_list}
    resp = requests.patch(
        url,
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(
            f"UC tag API returned {resp.status_code}: {resp.text[:200]}"
        )
    logger.info("Applied %d UC tag(s) to %s", len(tag_list), full_uc_name)


def _build_tags(rollup_name: str, extra_tags: dict[str, str] | None) -> dict[str, str]:
    """Build the complete tag map for a RollUp export table."""
    tags: dict[str, str] = {
        "lakets.managed_by": "lakets",
        "lakets.rollup_name": rollup_name,
    }
    if extra_tags:
        tags.update(extra_tags)
    return tags


def _derive_uc_table_name(delta_table: str, rollup_name: str) -> str:
    """Derive UC table name from the Delta table 3-part name or rollup name."""
    parts = delta_table.split(".")
    if len(parts) == 3 and parts[2]:
        return parts[2]
    return re.sub(r"[^a-zA-Z0-9_]", "_", rollup_name)


def _get_host(w: WorkspaceClient) -> str:
    host = w.config.host
    if not host:
        raise RuntimeError("Databricks host not configured in WorkspaceClient")
    return host.rstrip("/")


def _get_warehouse_id(w: WorkspaceClient) -> str:
    """Return the first running SQL warehouse id."""
    for wh in w.warehouses.list():
        if wh.state and wh.state.name == "RUNNING":
            return wh.id
    raise RuntimeError("No running SQL warehouse found")


def _run_sql_statement(w: WorkspaceClient, warehouse_id: str, statement: str) -> None:
    """Execute a SQL statement via Databricks SQL statement API (blocking)."""
    resp = w.statement_execution.execute_statement(
        statement=statement,
        warehouse_id=warehouse_id,
        wait_timeout="30s",
    )
    if resp.status and resp.status.state and resp.status.state.name not in ("SUCCEEDED", "RUNNING"):
        raise RuntimeError(
            f"SQL statement failed ({resp.status.state.name}): {statement!r}"
        )


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    instance = sys.argv[1] if len(sys.argv) > 1 else os.environ["LAKETS_INSTANCE"]
    catalog = sys.argv[2] if len(sys.argv) > 2 else os.environ["LAKETS_UC_CATALOG"]
    schema = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("LAKETS_UC_SCHEMA", "lakets_exports")
    name = sys.argv[4] if len(sys.argv) > 4 else None
    run(instance, catalog, schema, name)
