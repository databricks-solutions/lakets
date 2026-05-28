<!--
Thanks for contributing to LakeTS!

Please complete each section below. Skip a section only if it genuinely
doesn't apply, and add a short "N/A — reason" line so reviewers know
you considered it.
-->

## Summary

<!-- One or two sentences: what changes, and why? -->

## Type of change

<!-- Tick the relevant boxes. Multiple may apply. -->

- [ ] `feat:` New feature (user-visible behavior change)
- [ ] `fix:` Bug fix
- [ ] `perf:` Performance improvement
- [ ] `refactor:` Refactor (no behavior change)
- [ ] `docs:` Documentation only
- [ ] `test:` Tests only
- [ ] `chore:` / `ci:` Tooling, dependencies, or workflows
- [ ] Breaking change (requires migration; describe below)

## SQL module(s) touched

<!-- e.g. `01_chronotable.sql`, `03_rollup.sql`, `09_lvc.sql`, or N/A -->

## Test plan

<!--
- Which test suite(s) cover this change?
- Did you add or update tests? Link them.
- Did you run them locally against a Lakebase instance? Paste the
  PASSED line counts or a summary.
-->

## Migration impact

<!--
Does this change schema, metadata tables (`lakets._*`), or function
signatures in a way that requires an existing install to migrate?

If yes:
- Add a migration file under `migrations/` (naming: V{from}_V{to}_{desc}.sql).
- Confirm the file passes the `Migration Lint` CI job.
- Reference the migration here.

If no: write "N/A — additive change only" or similar.
-->

## Related issues / context

<!-- e.g. Closes #123, Refs #456, or design doc link -->

## Reviewer checklist

- [ ] Conventional Commit prefix in the PR title (e.g. `feat:`, `fix:`)
- [ ] CI is green
- [ ] No secrets or credentials in the diff
- [ ] Updated `CHANGELOG.md` (if applicable, after Tier 2 lands)
- [ ] Updated docs (if behavior changed)
