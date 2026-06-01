"""
LakeTS Python Workflow Pattern Tests

Unit tests validating that SQL query construction uses safe patterns
(parameterized queries, psycopg2.sql.Identifier) instead of f-strings.

These tests run without a live database — all external calls are mocked.
"""
import ast
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


class TestCompressionJobPatterns:
    """Verify compression_job.py uses safe SQL patterns."""

    SOURCE_PATH = "databricks/workflows/compression_job.py"

    def test_drop_table_uses_identifier(self):
        """T9: DROP TABLE uses sql.Identifier, not %-formatting."""
        source = _read_source(self.SOURCE_PATH)
        assert '"DROP TABLE IF EXISTS %s.%s" %' not in source, \
            "compression_job.py still uses %-format for DROP TABLE"

    def test_uses_chronotable_registry(self):
        """T10: References _chronotable_registry, not _hypertable_registry."""
        source = _read_source(self.SOURCE_PATH)
        assert "_hypertable_registry" not in source, \
            "compression_job.py still references legacy _hypertable_registry"
        assert "_chronotable_registry" in source, \
            "compression_job.py should reference _chronotable_registry"

    def test_no_dead_jdbc_url(self):
        """T11: Dead jdbc_url code has been removed."""
        source = _read_source(self.SOURCE_PATH)
        assert "jdbc_url" not in source, \
            "compression_job.py still has dead jdbc_url code"


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
