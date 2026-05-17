# Changelog

All notable changes to this project are documented in this file.

The format is inspired by Keep a Changelog and this project uses date-based release entries.

## [2026-05-17]

### Fixed

- Skip ACL restoration during `pg_restore` to avoid missing-role grant failures. (`ad0513f`)
- Skip object ownership restoration during `pg_restore` to avoid missing-role ownership errors. (`db18d3f`)
- Install `bash` in the GitLab CI Alpine image to prevent shell-related job failures. (`380ab53`)
- Wait for PostgreSQL readiness in GitLab CI jobs before running checks. (`4580a6f`)
- Move GitLab CI variables to top-level scope for consistent job behavior. (`62f78f6`)

### Documentation

- Update project documentation and add governance/compliance documents: `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, and `CODE_OF_CONDUCT.md`. (`c8e385b`)

### Merged

- Merge branch `chore/review-readme` into `develop`. (`3484196`)
