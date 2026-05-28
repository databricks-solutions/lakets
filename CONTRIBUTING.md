# Contributing to LakeTS

Thanks for your interest in LakeTS. This document walks through how to propose changes, run tests, and get a PR merged.

## Before you start

- **Read the [README](./README.md)** and skim [`CLAUDE.md` in the source tree](https://github.com/databricks-solutions/lakets/blob/main/README.md) for architecture context.
- **Search [existing issues](https://github.com/databricks-solutions/lakets/issues)** to avoid duplicate work. For bugs, file an issue first; for features, open a discussion or feature-request issue so we can align on scope before you implement.
- **Security issues** must be reported privately via [GitHub Security Advisories](https://github.com/databricks-solutions/lakets/security/advisories/new) — not as public issues or PRs.

## Development setup

LakeTS is pure SQL (PL/pgSQL) plus a small Python wrapper for Databricks workflows. You need:

- **PostgreSQL 16+** or a Databricks Lakebase instance to run integration tests
- **Python 3.10+** for the workflow code and lint/test tooling
- **`psql`** CLI for running SQL test suites

Clone and set up:

```bash
git clone https://github.com/databricks-solutions/lakets.git
cd lakets
pip install -r requirements.txt
```

For Lakebase, the connection string uses OAuth:

```bash
export DATABRICKS_TOKEN=$(databricks auth token --host <workspace-url>)
```

## Branching and commits

- **Branch from `main`** with a descriptive name: `feat/lvc-cardinality`, `fix/rollup-watermark`, `chore/...`.
- **Use Conventional Commits** for both commits and PR titles:
  - `feat:` new user-visible capability
  - `fix:` bug fix
  - `perf:` performance work
  - `refactor:` no behavior change
  - `docs:` documentation only
  - `test:` tests only
  - `chore:` / `ci:` tooling, deps, workflows
  - Add `!` for breaking changes: `feat!: drop deprecated foo`
- **One logical change per PR.** Mechanical refactors and feature work in the same PR make review hard.

## Running tests

```bash
# Build the single-file distribution
make build

# Install on a clean Lakebase instance
psql -h <host> -U <user> -d <database> -f dist/lakets.sql

# Run all SQL test suites
for f in tests/test_*.sql; do psql -h <host> -U <user> -d <database> -f "$f"; done

# Run Python tests (no live DB required)
python3 -m pytest tests/test_python_patterns.py -v
```

Each SQL test file is a self-contained PL/pgSQL block that creates its own fixtures, asserts, and cleans up. Tests are independent and can run in any order.

## Adding a migration

If your change modifies any `lakets.*` schema, metadata table, or function signature in a way that breaks an existing install:

1. Add a file under `migrations/` named `V{from}_V{to}_{description}.sql` — e.g. `V0_1_2_V0_1_3_add_chunk_compression_ratio.sql`.
2. The migration must:
   - Begin with a version guard (`FROM lakets._version WHERE version = '...'`)
   - End with an `INSERT INTO lakets._version` recording the new version
   - Be idempotent (safe to re-run)
3. Bump the `VERSION` file in the same PR.
4. The `Migration Lint` CI job will verify naming and structure.

## CI checks

Every PR runs:

- **SQL Security Lint** — flags unsafe dynamic SQL patterns (`EXECUTE` with string interpolation, etc.)
- **Python Security Lint** — flags f-string SQL injection
- **Secret Scan** — hardcoded credentials
- **Migration Lint** — migration file structure (if any added)
- **Python Unit Tests** — `tests/test_python_patterns.py`

All checks must pass before merge.

## Code review

PRs require at least one approving review. Comments marked `nit:` are optional; everything else should be addressed or explicitly deferred with a follow-up issue.

We squash-merge to keep `main` linear, so don't worry about cleaning up your branch history — just write clear commit messages so the squash message is good.

## Release process

Releases happen from `main` via tag push. See the "Release Process" section in [README.md](./README.md). Maintainers handle releases; contributors don't need to bump versions or tag.

## License

By contributing, you agree that your contributions will be licensed under the [Databricks License](./LICENSE.md). You also represent that you have the right to make the contribution.
