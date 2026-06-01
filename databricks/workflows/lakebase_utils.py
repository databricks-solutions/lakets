"""
LakeTS Lakebase Connection Utilities

Shared helper for all Databricks workflow jobs to connect to Lakebase using a
short-lived OAuth credential minted via the Databricks SDK. Follows the
psycopg3 connection pattern from the Databricks docs:
https://docs.databricks.com/aws/en/oltp/instances/query/notebook#psycopg3

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
(requires databricks-sdk >= 0.56.0).

The service principal must also have a matching **Postgres role** on the
Lakebase instance, granted the privileges the job needs (see the "Workflow
jobs" doc). The role name defaults to the running identity (``current_user``);
override it with the ``LAKETS_PG_ROLE`` environment variable if it differs.

Lakebase OAuth tokens are short-lived (~1 h) and rotate. ``_oauth_connection_class``
mints a fresh token on every physical connect, so a reconnect never carries a
stale password.
"""
import os
import uuid
from contextlib import contextmanager

import psycopg
from databricks.sdk import WorkspaceClient


def _oauth_connection_class(workspace: WorkspaceClient, instance_name: str):
    """Build a psycopg connection class that injects a freshly minted Lakebase
    OAuth token as the password on every connect (psycopg3 pattern from the docs).

    Generating the credential inside ``connect()`` — rather than once up front —
    means any reconnect transparently obtains a non-expired token.
    """

    class _OAuthConnection(psycopg.Connection):
        @classmethod
        def connect(cls, conninfo: str = "", **kwargs):
            cred = workspace.database.generate_database_credential(
                request_id=str(uuid.uuid4()),
                instance_names=[instance_name],
            )
            kwargs["password"] = cred.token
            return super().connect(conninfo, **kwargs)

    return _OAuthConnection


def get_lakebase_connection(instance_name: str, database: str = "databricks_postgres"):
    """Open a fresh connection to a Lakebase instance, authenticating as the
    job's service principal via a machine-to-machine OAuth credential."""
    w = WorkspaceClient()
    instance = w.database.get_database_instance(name=instance_name)
    pg_role = os.environ.get("LAKETS_PG_ROLE") or w.current_user.me().user_name
    connection_class = _oauth_connection_class(w, instance_name)
    return connection_class.connect(
        host=instance.read_write_dns,
        port=5432,
        dbname=database,
        user=pg_role,
        sslmode="require",
        connect_timeout=30,
        options="-c statement_timeout=600000 -c lock_timeout=30000",
        autocommit=True,
    )


@contextmanager
def lakebase_cursor(instance_name: str, database: str = "databricks_postgres"):
    """Context manager yielding a cursor connected to Lakebase."""
    conn = get_lakebase_connection(instance_name, database)
    try:
        cur = conn.cursor()
        try:
            yield cur
        finally:
            cur.close()
    finally:
        conn.close()


def fetch_all(cur, sql: str, params=None):
    """Execute SQL and return all rows as list of dicts."""
    cur.execute(sql, params)
    cols = [desc[0] for desc in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]
