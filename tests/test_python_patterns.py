"""
LakeTS Python Workflow Pattern Tests

Unit tests validating that SQL query construction uses safe patterns
(parameterized queries, psycopg.sql.Identifier) instead of f-strings.

These tests run without a live database — all external calls are mocked.
"""
import ast
import glob
import inspect
import re
import textwrap
from unittest.mock import MagicMock, patch

import pytest


# ─────────────────────────────────────────────────────────────────────────────
# Source code pattern tests (static analysis)
# ─────────────────────────────────────────────────────────────────────────────

def _read_source(module_path: str) -> str:
    """Read source code from a file path."""
    with open(module_path) as f:
        return f.read()


class TestColdRollupRefreshPatterns:
    """Verify cold_rollup_refresh.py uses safe SQL patterns."""

    SOURCE_PATH = "databricks/workflows/cold_rollup_refresh.py"

    def test_validates_bucket_col(self):
        """T5: cold_rollup_refresh validates bucket_col as safe identifier."""
        source = _read_source(self.SOURCE_PATH)
        assert "re.match" in source, \
            "cold_rollup_refresh.py should validate bucket_col with regex"

    def test_uses_sql_identifier_for_delete(self):
        """T6: DELETE uses sql.Identifier, not f-string."""
        source = _read_source(self.SOURCE_PATH)
        assert 'f"DELETE FROM' not in source, \
            "cold_rollup_refresh.py still uses f-string for DELETE"

    def test_uses_sql_identifier_for_insert(self):
        """T7: INSERT uses sql.Identifier, not f-string."""
        source = _read_source(self.SOURCE_PATH)
        assert 'f"INSERT INTO' not in source, \
            "cold_rollup_refresh.py still uses f-string for INSERT"

    def test_tracks_failures(self):
        """T8: Failures are tracked and logged."""
        source = _read_source(self.SOURCE_PATH)
        assert "failures" in source, \
            "cold_rollup_refresh.py should track failures"


class TestTieringJobPatterns:
    """Verify tiering_job.py uses safe SQL patterns and delegates the drop to SQL."""

    SOURCE_PATH = "databricks/workflows/tiering_job.py"

    def test_delegates_drop_to_tier_chunk(self):
        """T9: The partition drop is delegated to lakets.tier_chunk (no raw DROP in Python)."""
        source = _read_source(self.SOURCE_PATH)
        assert "lakets.tier_chunk" in source, \
            "tiering_job.py should call lakets.tier_chunk to perform the gated drop"
        assert "DROP TABLE" not in source, \
            "tiering_job.py should not issue DROP TABLE directly; tier_chunk owns the drop"

    def test_uses_chronotable_registry(self):
        """T10: References _chronotable_registry, not _hypertable_registry."""
        source = _read_source(self.SOURCE_PATH)
        assert "_hypertable_registry" not in source, \
            "tiering_job.py still references legacy _hypertable_registry"
        assert "_chronotable_registry" in source, \
            "tiering_job.py should reference _chronotable_registry"

    def test_no_spark(self):
        """T11: Tiering is pure Lakebase SQL — no Spark dependency."""
        source = _read_source(self.SOURCE_PATH)
        assert "pyspark" not in source and "SparkSession" not in source, \
            "tiering_job.py should be Spark-free"


class TestLakebaseUtilsPatterns:
    """Verify lakebase_utils.py has proper timeouts and cleanup."""

    SOURCE_PATH = "databricks/workflows/lakebase_utils.py"

    def test_connect_timeout_present(self):
        """T12: Connection includes connect_timeout."""
        source = _read_source(self.SOURCE_PATH)
        assert "connect_timeout" in source, \
            "lakebase_utils.py missing connect_timeout"

    def test_statement_timeout_present(self):
        """T13: Connection includes statement_timeout."""
        source = _read_source(self.SOURCE_PATH)
        assert "statement_timeout" in source, \
            "lakebase_utils.py missing statement_timeout"

    def test_cursor_cleanup_on_error(self):
        """T14: Context manager properly nests try/finally for conn and cursor."""
        source = _read_source(self.SOURCE_PATH)
        # Should have nested try/finally for proper cleanup
        assert source.count("finally:") >= 2, \
            "lakebase_utils.py should have nested try/finally for conn+cursor cleanup"


class TestRollupRefreshPatterns:
    """Verify rollup_refresh.py tracks failures."""

    SOURCE_PATH = "databricks/workflows/rollup_refresh.py"

    def test_tracks_failures(self):
        """T15: rollup_refresh tracks and logs failures."""
        source = _read_source(self.SOURCE_PATH)
        assert "failures" in source, \
            "rollup_refresh.py should track failures"
        assert "failures.append" in source, \
            "rollup_refresh.py should append to failures list"

    def test_refreshes_in_dag_order(self):
        """T16: rollup_refresh uses refresh_rollup_cascade (DAG order), not an
        alphabetical refresh_rollup() loop that ignores dependencies."""
        source = _read_source(self.SOURCE_PATH)
        assert "refresh_rollup_cascade" in source, \
            "rollup_refresh.py should refresh via refresh_rollup_cascade() for DAG-correct order"


# ─────────────────────────────────────────────────────────────────────────────
# Schema-drift guard
# ─────────────────────────────────────────────────────────────────────────────

WORKFLOW_GLOB = "databricks/workflows/*.py"
SQL_GLOB = "sql/*.sql"

# `lakets.<object>` references in Python (registries, functions used in SQL).
_LAKETS_REF = re.compile(r"\blakets\.([a-zA-Z_][a-zA-Z0-9_]*)")
# Logger names like getLogger("lakets.partition_manager") are not DB objects.
_GETLOGGER = re.compile(r"getLogger\([^)]*\)")
# `CREATE [OR REPLACE] TABLE|VIEW|FUNCTION|... [IF NOT EXISTS] lakets.<object>`.
_DEFINITION = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?"
    r"(?:TABLE|VIEW|MATERIALIZED\s+VIEW|FUNCTION|AGGREGATE|PROCEDURE)\s+"
    r"(?:IF\s+NOT\s+EXISTS\s+)?lakets\.([a-zA-Z_][a-zA-Z0-9_]*)",
    re.IGNORECASE,
)


def _defined_lakets_objects() -> set:
    """All lakets.* tables/views/functions/aggregates defined across sql/*.sql."""
    defined = set()
    for path in glob.glob(SQL_GLOB):
        with open(path) as f:
            defined.update(_DEFINITION.findall(f.read()))
    return defined


def _referenced_lakets_objects(source: str) -> set:
    """lakets.* objects referenced in a workflow file, excluding logger names."""
    return set(_LAKETS_REF.findall(_GETLOGGER.sub("", source)))


class TestSchemaReferences:
    """Every ``lakets.<object>`` the workflow jobs reference must exist in the
    SQL modules. Guards against schema drift like the hypertable->chronotable
    rename that left ``lakets._hypertable_registry`` references behind in
    partition_manager.py / retention_job.py and only failed at runtime."""

    def test_sql_definitions_parse(self):
        """Sanity: the SQL modules yield a non-empty set of lakets objects."""
        defined = _defined_lakets_objects()
        assert "_chronotable_registry" in defined, \
            "expected core registries in sql/*.sql — check SQL_GLOB / regex"

    def test_workflow_lakets_references_are_defined(self):
        """No workflow file may reference a lakets object absent from sql/*.sql."""
        defined = _defined_lakets_objects()
        problems = []
        for path in sorted(glob.glob(WORKFLOW_GLOB)):
            refs = _referenced_lakets_objects(_read_source(path))
            missing = sorted(r for r in refs if r not in defined)
            if missing:
                problems.append(f"{path.split('/')[-1]}: {missing}")
        assert not problems, (
            "Workflow jobs reference lakets objects not defined in sql/*.sql "
            "(schema drift):\n  " + "\n  ".join(problems)
        )
