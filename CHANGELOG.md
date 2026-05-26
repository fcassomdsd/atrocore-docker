# Changelog

All notable changes to this project are documented in this file.

The format is inspired by Keep a Changelog and uses semantic versioning for release entries.

## [0.1.0] - 2026-05-26

First development release. This version has not been deployed to production environments yet.

### Fixed

- Skip ACL restoration during `pg_restore` to avoid missing-role grant failures. (`ad0513f`)
- Skip object ownership restoration during `pg_restore` to avoid missing-role ownership errors. (`db18d3f`)
- Install `bash` in the GitLab CI Alpine image to prevent shell-related job failures. (`380ab53`)
- Wait for PostgreSQL readiness in GitLab CI jobs before running checks. (`4580a6f`)
- Move GitLab CI variables to top-level scope for consistent job behavior. (`62f78f6`)

### Documentation

- Update project documentation and add governance/compliance documents: `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, and `CODE_OF_CONDUCT.md`. (`c8e385b`)
