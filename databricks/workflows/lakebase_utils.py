"""
LakeTS Lakebase Connection Utilities

Shared helper for all Databricks workflow jobs to connect to a **Lakebase
Autoscaling** project using a short-lived OAuth credential minted via the
Databricks SDK. Follows the psycopg3 connection pattern from the Databricks
docs: https://docs.databricks.com/aws/en/oltp/instances/query/notebook#psycopg3

Authentication (machine-to-machine OAuth)
-----------------------------------------
The jobs run as a Databricks **service principal**. Inside a Databricks job the
default ``WorkspaceClient()`` resolves that identity automatically. For runs
outside Databricks, configure the service principal's M2M OAuth credentials via
the standard SDK environment variables and the SDK picks them up unchanged:

    DATABRICKS_HOST           https://<workspace-url>/
    DATABRICKS_CLIENT_ID      <service principal application id>
    DATABRICKS_CLIENT_SECRET  <service principal OAuth secret>

See: https://docs.databricks.com/aws/en/oltp/instances/authentication#obtain-an-oauth-token-in-a-machine-to-machine-flow
Requires databricks-sdk >= 0.81.0 (the ``w.postgres`` Autoscaling API).

Connection model (Lakebase Autoscaling)
----------------------------------------
Autoscaling exposes connectivity through a project's primary read-write
**endpoint**, not a provisioned instance. Given a project name we resolve
``projects/<name>`` -> default branch -> read-write endpoint, read the host from
``w.postgres.get_endpoint(...).status.hosts.host``, and mint the Postgres
password with ``w.postgres.generate_database_credential(endpoint=...)``. Set
``LAKETS_LAKEBASE_ENDPOINT`` to a full endpoint path to skip resolution.

The service principal must have a matching **Postgres role** on the Lakebase
branch, granted the privileges the job needs (see the "Workflow jobs" doc). The
role defaults to the running identity (``current_user``); override it with
``LAKETS_PG_ROLE``.

Tokens are short-lived (~1 h) and rotate; ``_oauth_connection_class`` mints a
fresh one on every physical connect, so a reconnect never carries a stale
password.
"""
import os
from contextlib import contextmanager

import psycopg
from databricks.sdk import WorkspaceClient


def _resolve_endpoint(workspace: WorkspaceClient, project_name: str) -> str:
    """Resolve a Lakebase Autoscaling project name to its primary read-write
    endpoint resource name (``projects/<id>/branches/<branch>/endpoints/<id>``).

    Honors a ``LAKETS_LAKEBASE_ENDPOINT`` override for non-default layouts.
    """
    explicit = os.environ.get("LAKETS_LAKEBASE_ENDPOINT")
    if explicit:
        return explicit

    project = project_name if project_name.startswith("projects/") else f"projects/{project_name}"

    # Default branch (fall back to the conventional 'production' default).
    branch = f"{project}/branches/production"
    try:
        default = next(
            (b for b in workspace.postgres.list_branches(parent=project)
             if getattr(getattr(b, "status", None), "default", False)),
            None,
        )
        if default and getattr(default, "name", None):
            branch = default.name
    except Exception:
        pass

    endpoints = list(workspace.postgres.list_endpoints(parent=branch))
    if not endpoints:
        raise RuntimeError(f"No Lakebase endpoints found under {branch}")

    def _is_read_write(endpoint) -> bool:
        endpoint_type = (
            getattr(endpoint, "endpoint_type", None)
            or getattr(getattr(endpoint, "spec", None), "endpoint_type", None)
        )
        return "READ_WRITE" in str(endpoint_type)

    primary = next((e for e in endpoints if _is_read_write(e)), endpoints[0])
    return primary.name


def _oauth_connection_class(workspace: WorkspaceClient, endpoint: str):
    """Build a psycopg connection class that injects a freshly minted Lakebase
    OAuth token as the password on every connect (psycopg3 pattern from the docs).
    """

    class _OAuthConnection(psycopg.Connection):
        @classmethod
        def connect(cls, conninfo: str = "", **kwargs):
            cred = workspace.postgres.generate_database_credential(endpoint=endpoint)
            kwargs["password"] = cred.token
            return super().connect(conninfo, **kwargs)

    return _OAuthConnection


def get_lakebase_connection(project_name: str, database: str = "databricks_postgres"):
    """Open a fresh connection to a Lakebase Autoscaling project, authenticating
    as the job's service principal via a machine-to-machine OAuth credential."""
    w = WorkspaceClient()
    endpoint = _resolve_endpoint(w, project_name)
    host = w.postgres.get_endpoint(name=endpoint).status.hosts.host
    pg_role = os.environ.get("LAKETS_PG_ROLE") or w.current_user.me().user_name
    connection_class = _oauth_connection_class(w, endpoint)
    return connection_class.connect(
        host=host,
        port=5432,
        dbname=database,
        user=pg_role,
        sslmode="require",
        connect_timeout=30,
        options="-c statement_timeout=600000 -c lock_timeout=30000",
        autocommit=True,
    )


@contextmanager
def lakebase_cursor(project_name: str, database: str = "databricks_postgres"):
    """Context manager yielding a cursor connected to Lakebase."""
    conn = get_lakebase_connection(project_name, database)
    try:
        cur = conn.cursor()
        try:
            yield cur
        finally:
            cur.close()
    finally:
        conn.close()


def fetch_all(cur, sql: str, params=None):
    """Execute SQL and return every row as a dict keyed by column name."""
    cur.execute(sql, params)
    cols = [desc[0] for desc in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]
