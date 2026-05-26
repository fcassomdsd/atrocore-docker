# Release Notes - v0.1.0 (First Development Pre-production Release)

Release date: 2026-05-26

## Release Summary

Version 0.1.0 is the first development pre-production release of this repository. It focuses on improving database restore reliability, hardening CI behavior, and establishing core project documentation for collaboration and governance.

This version has not been deployed to production environments yet.

## Highlights

### For Users

- More reliable database restore behavior in environments where expected database roles do not exist.
- Better consistency when initializing or validating environments through the provided workflows.

### For Stakeholders

- Foundation-level governance and compliance documents are now included (`LICENSE`, `NOTICE`, `CONTRIBUTING`, and `CODE_OF_CONDUCT`).
- CI reliability improvements reduce setup friction and improve confidence in repeatable validation.
- Better organization and control of foundational data through improved restore and validation workflows.

### For Developers and DevOps

- `pg_restore` behavior now skips ACL and ownership restoration to avoid role-related failures in local or fresh environments.
- GitLab CI jobs now ensure required shell runtime and PostgreSQL readiness before checks run.
- CI variable scope was normalized to top-level declarations for more predictable job behavior.

## Included Changes

- Database restore hardening in `scripts/restore-db.sh`.
- CI robustness updates in `.gitlab-ci.yml`.
- Documentation additions and updates in `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, and `CODE_OF_CONDUCT.md`.

## Installation and Upgrade

For installation and upgrade instructions, refer to `README.md`.
