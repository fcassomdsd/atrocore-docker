# Changelog

All notable changes to this project are documented in this file.

The format is inspired by Keep a Changelog and uses semantic versioning for release entries.

## [Unreleased]

### Added

- `metadata/` as the version-controlled source of truth for AtroCore entity metadata, with `scripts/install-metadata.sh` to install it into the gitignored `web-data/` runtime tree.
- `ActivityType` reference entity (oversight activity type: `A` Auditoría, `I` Inspección, `M` Monitoreo, `D` Revisión documental, `S` Análisis de suceso).
- `sql/seed-nomenclatura-catalog.sql` plus `scripts/seed-nomenclatura.sh` to seed the `Specialty` and `ActivityType` reference catalogs idempotently.
- `make metadata-install` and `make db-seed-nomenclatura` targets.

### Changed

- Replaced the `Specialty` catalog with the client's flat 16-code standard (APR, AVIS, FAU, PAV, SSEI, AIM, ATS, COM, ECNS, EMET, FIS, MET, NAV, SAR, SUR, DPR).
- `Inspection.inspectionType` and `InspectionCadence.inspectionType` are now `activityType` links to `ActivityType` instead of free-text varchars, so the single-letter code embedded in generated document IDs comes from a controlled vocabulary.

### Removed

- The `Specialty` grouping concept: the `AssignmentGroup` link and the `SpecialtyHierarchy` self-relation, along with the tree list/detail views. `Specialty` is now a flat `Base` entity.

First development release. This version has not been deployed to production environments yet.

### Fixed

- Skip ACL restoration during `pg_restore` to avoid missing-role grant failures. (`ad0513f`)
- Skip object ownership restoration during `pg_restore` to avoid missing-role ownership errors. (`db18d3f`)
- Install `bash` in the GitLab CI Alpine image to prevent shell-related job failures. (`380ab53`)
- Wait for PostgreSQL readiness in GitLab CI jobs before running checks. (`4580a6f`)
- Move GitLab CI variables to top-level scope for consistent job behavior. (`62f78f6`)

### Documentation

- Update project documentation and add governance/compliance documents: `README.md`, `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, and `CODE_OF_CONDUCT.md`. (`c8e385b`)
