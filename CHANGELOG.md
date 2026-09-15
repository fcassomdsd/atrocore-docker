# Changelog

All notable changes to this project are documented in this file.

The format is inspired by Keep a Changelog and releases are dated — see CONTRIBUTING.md, "Versioning and releases".

## [Unreleased]

### Added

- `metadata/` as the version-controlled source of truth for AtroCore entity metadata, with `scripts/install-metadata.sh` to install it into the gitignored `web-data/` runtime tree.
- `ActivityType` reference entity (oversight activity type: `A` Auditoría, `I` Inspección, `M` Monitoreo, `D` Revisión documental, `S` Análisis de suceso).
- `sql/seed-nomenclatura-catalog.sql` plus `scripts/seed-nomenclatura.sh` to seed the `Specialty` and `ActivityType` reference catalogs idempotently.
- `make metadata-install` and `make db-seed-nomenclatura` targets.
- **A committed synthetic demo dataset, so a fresh clone is no longer empty.** Every operational record (locations, providers, inspectors, site visits, inspections) existed only inside the binary `atrocore.dump`/`db-dumps/*.dump` files, which are gitignored and were purged from history in the P0 secret cleanup — so `git clone` + `docker compose up` produced an app with nothing to click. `sql/seed-demo-dataset.sql` + `scripts/seed-demo-dataset.sh` add one fictional airport (ICAO `ZZZZ`, ICAO's own "unknown aerodrome" placeholder, so generated codes are obviously synthetic), two service providers, three inspectors, their services and specialties, a site visit three weeks ahead of the day you seed, two inspections and the interview schedules the plan generator requires. Everything is invented (`.invalid` e-mail addresses, `Demo …` names), contains no credentials, and is **additive**: it only ever writes rows whose `id` starts with `demo-`, so it is safe against a database that already holds real records. `--remove` deletes exactly those rows. `make db-seed-demo YES=1` / `make db-seed-demo-remove YES=1`. The visit is seeded as `Planned` because `/siteVisits` hides visits that are still `Created`. Verified live: 38 rows created, 0 left after `--remove`, 38 after re-seeding, and `/siteVisits`, `/providers?siteVisit=`, `/location` and `/inspectors?specialty=` all return the demo records while the existing smoke harness stays 15/15.
- **`demo_seed_check` replaced by `validate:seed`, which actually runs.** The old job skipped itself whenever `atrocore.dump` was absent — and since dumps are gitignored, that was every run — then asserted only that "some public tables exist", which was already true against an empty database. It cannot be fixed by removing the skip: the `atro-web` image this pipeline builds starts Apache with a DocumentRoot that does not exist (the AtroCore application is never installed), so no schema is ever created and there is nothing to seed. The job is therefore replaced by `scripts/validate-demo-seed.py`, which runs in a `python:3.12-alpine` container with no Docker at all and enforces the invariants a database would otherwise only catch late: additive-only (every `DELETE` scoped to `demo-` rows), no `TRUNCATE`, every row id namespaced, the row count matching its documentation (38), and `--remove` covering every table the seed writes. Both new failure modes are verified to trip. **Open CI gap, reported rather than papered over:** the pipeline never brings up a working AtroCore, so nothing in CI exercises the metadata install or the schema sync end to end.

### Changed

- Replaced the `Specialty` catalog with the client's flat 16-code standard (APR, AVIS, FAU, PAV, SSEI, AIM, ATS, COM, ECNS, EMET, FIS, MET, NAV, SAR, SUR, DPR).
- `Inspection.inspectionType` and `InspectionCadence.inspectionType` are now `activityType` links to `ActivityType` instead of free-text varchars, so the single-letter code embedded in generated document IDs comes from a controlled vocabulary.
- **Versioning and tagging standardised across the platform.** Releases are tagged `YYYY-MM-DD` (CalVer) after the date of the newest `## [YYYY-MM-DD]` CHANGELOG section, with `YYYY-MM-DD.2` for a second release on the same day. The release jobs now run `scripts/release-tag.sh`, which fails when that section is missing, when `CHANGELOG.md` is unchanged since the previous release, or when the tag already exists; `scripts/release-tag.test.sh` is its self-test. See CONTRIBUTING.md, "Versioning and releases".
- **README drift fixed.** Corrected the stack summary from PHP 8.2 to the actual PHP 8.4 (`.docker/php/Dockerfile`), corrected the "healthy" wording in the quick-start checklist (the compose services define no healthcheck, so they report `running`, never `healthy`), and archived the superseded `RELEASE_NOTES_v0.1.0.md` into `docs/archive/`.

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
