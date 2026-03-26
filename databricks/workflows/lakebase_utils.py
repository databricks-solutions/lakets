"""
LakeTS Lakebase Connection Utilities
Shared helper for all Databricks workflow jobs to connect to Lakebase.
"""
import uuid
from contextlib import contextmanager

import psycopg2
from databricks.sdk import WorkspaceClient


def get_lakebase_connection(instance_name: str, database: str = "databricks_postgres"):
    """Create a fresh connection to a Lakebase instance using OAuth."""
    w = WorkspaceClient()
    cred = w.database.generate_database_credential(
        instance_names=[instance_name],
        request_id=str(uuid.uuid4()),
    )
    instance = w.database.get_database_instance(name=instance_name)
    conn = psycopg2.connect(
        host=instance.read_write_dns,
        port=5432,
        dbname=database,
        user=w.current_user.me().user_name,
        password=cred.token,
        sslmode="require",
    )
    conn.autocommit = True
    return conn


@contextmanager
def lakebase_cursor(instance_name: str, database: str = "databricks_postgres"):
    """Context manager yielding a cursor connected to Lakebase."""
    conn = get_lakebase_connection(instance_name, database)
    cur = conn.cursor()
    try:
        yield cur
    finally:
        cur.close()
        conn.close()


def fetch_all(cur, sql: str, params=None):
    """Execute SQL and return all rows as list of dicts."""
    cur.execute(sql, params)
    cols = [desc[0] for desc in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]
