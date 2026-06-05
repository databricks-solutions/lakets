<!--
Title must use a Conventional Commit prefix (feat:, fix:, perf:, refactor:,
docs:, test:, chore:, ci:). Fill in each section; mark anything that doesn't
apply as "N/A — reason".
-->

## Summary

<!-- One or two sentences: what changes, and why? -->

## Type of change

- [ ] `feat:` New feature (user-visible behavior change)
- [ ] `fix:` Bug fix
- [ ] `perf:` Performance improvement
- [ ] `refactor:` Refactor (no behavior change)
- [ ] `docs:` Documentation only
- [ ] `test:` / `chore:` / `ci:` Tests, tooling, or workflows
- [ ] Breaking change (requires migration — describe below)

## SQL module(s) touched

<!-- e.g. 02_chronotable.sql, 04_rollup.sql, 09_lvc.sql — or N/A -->

## Test plan

<!--
- Which tests/test_*.sql suite(s) cover this? Did you add or update any?
- Run against a Lakebase instance and paste the "ALL ... TESTS PASSED" line(s).
-->

## Migration impact

<!--
Does this change schema, lakets._* metadata tables, or function signatures in a
way that requires existing installs to migrate? If yes, add migrations/V{from}_V{to}_{desc}.sql,
confirm the Migration Lint CI job passes, and reference it here. If no: "N/A — additive only".
-->

## Related issues

<!-- Closes #123, Refs #456, or a design-doc link -->

## Checklist

- [ ] Conventional Commit prefix in the PR title
- [ ] CI is green
- [ ] No secrets or credentials in the diff
- [ ] `build.sh` MODULES and `sql/99_install.sql` stay in sync (if a module was added/removed/renamed)
- [ ] Updated `CHANGELOG.md` (if user-visible)
- [ ] Updated docs under `website/` (if behavior changed)
