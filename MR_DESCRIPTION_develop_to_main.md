## Summary

This merge request promotes `develop` into `main` for the 2026-05-17 release.

Scope of this release:

- Fix `pg_restore` role/ownership related failures during restore workflows.
- Improve GitLab CI reliability for shell/runtime and PostgreSQL readiness.
- Add/update project governance and contribution documentation.

## Changes Included

### Fixes

- `fix: skip ACL restoration in pg_restore to avoid missing role grants` (`ad0513f`)
- `fix: skip object ownership in pg_restore to avoid missing role errors` (`db18d3f`)
- `fix: install bash in gitlab ci alpine image` (`380ab53`)
- `fix: wait for postgres readiness in gitlab ci jobs` (`4580a6f`)
- `fix: move gitlab ci variables to top-level` (`62f78f6`)

### Documentation and Compliance

- `docs: update README and add LICENSE, NOTICE, CONTRIBUTING, and CODE_OF_CONDUCT` (`c8e385b`)
- Merge commit: `Merge branch 'chore/review-readme' into 'develop'` (`3484196`)

## Files of Interest

- `.gitlab-ci.yml`
- `scripts/restore-db.sh`
- `README.md`
- `LICENSE`
- `NOTICE`
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `CHANGELOG.md`

## Validation

- CI pipeline jobs in `.gitlab-ci.yml` pass on this branch.
- Database restore flow no longer fails due to missing roles/ownership metadata.
- Documentation files are present and linked as expected.

## Risks

- Restore behavior now intentionally skips ACL and ownership metadata during `pg_restore`; this is appropriate for portability but may differ from environments that require strict ownership/privilege replication.

## Rollback Plan

- Revert this merge commit from `main` if regression is detected.
- If needed, restore previous restore behavior by reverting changes in `scripts/restore-db.sh`.

## Checklist

- [ ] Confirm `CHANGELOG.md` entry for `2026-05-17` is accurate.
- [ ] Confirm release branch `release/2026-05-17` is pushed.
- [ ] Confirm pipeline is green.
- [ ] Obtain required approvals.
