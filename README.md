# AtroCore Docker Environment

Docker Compose setup for running AtroCore/AtroPIM locally with:

- Apache + PHP 8.4 (`atro-web` service, see `.docker/php/Dockerfile`)
- PostgreSQL 15 (`db` service)
- Optional Traefik reverse proxy (via the provided example override file)

Official deployment documentation: https://help.atrocore.com/installation-and-maintenance/installation/docker-configuration

## Quick Start

### First 5 Minutes Checklist

Use this checklist if you are running the project for the first time:

1. Copy `.env.example` to `.env`.
2. Fill in database credentials in `.env`.
3. Start containers with `docker compose up -d --build`.
4. Wait until `db` and `atro-web` are `running` in `docker compose ps` (the compose services define no healthcheck, so they never report `healthy`).
5. Open http://localhost.

### 1. Prerequisites

- Docker Engine
- Docker Compose v2 (`docker compose` command)

### 2. Configure environment

Create your local environment file from the template:

```bash
cp .env.example .env
```

Set at least these variables in `.env`:

- `POSTGRES_PASSWORD`
- `POSTGRES_PIM_USER`
- `POSTGRES_PIM_PASSWORD`
- `POSTGRES_PIM_DB` (default: `atrocore`)

Other variables already have sensible defaults in `.env.example`.

Minimal `.env` example:

```dotenv
POSTGRES_PASSWORD=change_me_superuser
POSTGRES_PIM_USER=atro_user
POSTGRES_PIM_PASSWORD=change_me_app_user
POSTGRES_PIM_DB=atrocore

SKELETON_VARIANT=pim-no-demo
BUILD_VARIANT=base
PRODUCTION_DOMAIN=localhost
PRODUCTION_STABILITY=stable
```

Quick validation:

```bash
docker compose config >/dev/null && echo "Compose config is valid"
```

### 3. Start services

```bash
docker compose up -d --build
```

Or with Makefile shortcut:

```bash
make up
```

### 4. Open the application

By default, the web service is exposed on:

http://localhost

## Common Operations

### Stop services

```bash
docker compose down
```

Or:

```bash
make down
```

### Check service status

```bash
docker compose ps
```

### View logs

```bash
docker compose logs -f atro-web
docker compose logs -f db
```

## Database Backups

Create a timestamped PostgreSQL dump:

```bash
./scripts/backup-db.sh
```

Output location:

- `db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump`

Equivalent Make target:

```bash
make db-backup
```

## Database Restore

Restore into the default database from `.env` (`POSTGRES_PIM_DB`):

```bash
./scripts/restore-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump
```

Restore into a specific database:

```bash
./scripts/restore-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump another_db_name
```

Make target:

```bash
make db-restore DUMP=db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump
```

With explicit target DB:

```bash
make db-restore DUMP=db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump DB=another_db_name
```

Important:

- Run restore only when containers are up (`docker compose up -d`).
- Restore uses `pg_restore --clean --if-exists`, so existing objects in the target database are replaced.

## Demo Data Seeding

### Synthetic demo dataset (use this on a fresh install)

Nothing operational is committed as a dump, so a fresh clone comes up with
structurally complete but **empty** tables. The synthetic dataset closes that
gap: it is version-controlled, contains no secrets, is **additive** (it only
ever writes rows whose `id` starts with `demo-`) and is re-runnable, so it is
safe to run against a database that already holds real records.

```bash
./scripts/seed-nomenclatura.sh --yes      # spec_* / atype_* reference rows (run first)
./scripts/seed-demo-dataset.sh --yes      # the demo dataset
# or: make db-seed-demo YES=1

./scripts/seed-demo-dataset.sh --remove --yes   # delete every demo- row
# or: make db-seed-demo-remove YES=1
```

It creates one fictional airport (ICAO `ZZZZ` — ICAO's own "unknown aerodrome"
placeholder), two service providers, three inspectors, their services and
specialties, a site visit **three weeks ahead of the day you seed**, two
inspections and the interview schedules the plan generator needs. Document codes
carry the current year (`V-ZZZZ-2026-01`, `AV-ZZZZ-A-0001`); reference the
stable `id`s (`demo-sv-01`, `demo-insp-ans-01`) from scripts and docs. The visit
is seeded as `Planned`, because `/siteVisits` hides visits that are still
`Created` — a seed that stopped at `Created` would look like an empty database.

`sql/seed-demo-dataset.sql` carries the full rationale. **Never put a real
authority's data in it** — see the P0 finding in `TECHNICAL_DEBT_ANALYSIS.md`.

### Restoring a real dataset

> Database dumps are **not** committed to this repository — the previously tracked
> dumps contained live credential material (user password hashes and session
> tokens). Provision a seed dump from the release artifact store before seeding.

Seed the default database from a provisioned `atrocore.dump`:

```bash
./scripts/seed-demo-db.sh --yes
```

Seed from another dump file into a specific database:

```bash
./scripts/seed-demo-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump another_db_name --yes
```

Make target:

```bash
make db-seed YES=1
```

Custom dump/database with Make:

```bash
make db-seed DUMP=db-dumps/file.dump DB=another_db_name YES=1
```

Safety behavior:

- Seeding is destructive and requires explicit confirmation (`--yes` or `YES=1`).

## Entity Metadata and Reference Catalogs

AtroCore's live metadata lives under `web-data/<domain>/data/`, which is
**gitignored and disposable** — it is generated by the `atro-web` container and
CI recreates it from scratch on every run. Customisations therefore cannot be
edited there and kept.

Instead, the version-controlled source of truth is:

- `metadata/` — entity definitions, client definitions, scopes and layouts
  (see `metadata/README.md`)
- `sql/seed-nomenclatura-catalog.sql` — the reference **rows** for the
  `Specialty` and `ActivityType` catalogs

### Applying a metadata change

```bash
./scripts/install-metadata.sh          # copy metadata/ into web-data/, register tabs
docker compose exec atro-web php /var/www/localhost/console.php clear cache
docker compose exec atro-web php /var/www/localhost/console.php sql diff --show   # review DDL
docker compose exec atro-web php /var/www/localhost/console.php sql diff --run    # apply
./scripts/seed-nomenclatura.sh --yes   # load the catalog rows
```

Make shortcuts:

```bash
make metadata-install
make db-seed-nomenclatura YES=1
```

Notes:

- This AtroCore build has **no `rebuild` console command**. The equivalent is
  `clear cache` followed by `sql diff --run`.
- Always read `sql diff --show` before `--run`: it prints the exact DDL derived
  from the JSON metadata, including any `DROP`.
- `install-metadata.sh` falls back to a throwaway root container for files owned
  by `www-data`, so it works without `sudo`.
- The seed script is destructive (`--yes` required) but **idempotent** — it can
  be re-run safely.
- The tracked `*.dump` files predate this catalog standard. After restoring any
  dump, re-run the metadata install and the nomenclatura seed to bring the
  instance back to the current standard.

## Optional Traefik Reverse Proxy

This repository includes examples for Traefik in:

- `traefik/docker-compose.override.yaml.example`
- `traefik/traefik.yml.example`

If you want HTTPS and host-based routing, copy these files into the repository root (without the `.example` suffix), adapt them to your setup, and enable the related environment variables in `.env` (for example `LETS_ENCRYPT_EMAIL` and router names).

## Makefile Targets

Run `make help` to list all available shortcuts.

Main targets:

- `make up` - Start containers
- `make down` - Stop containers
- `make db-backup` - Create database backup
- `make db-restore DUMP=... [DB=...]` - Restore dump into DB
- `make db-seed-demo [DB=...] YES=1` - Seed the synthetic demo dataset (additive; safe)
- `make db-seed-demo-remove [DB=...] YES=1` - Delete every `demo-` row
- `make db-seed [DUMP=atrocore.dump] [DB=...] YES=1` - Restore a real dump instead (destructive)
- `make metadata-install` - Install tracked `metadata/` into `web-data/`
- `make db-seed-nomenclatura [DB=...] YES=1` - Seed Specialty/ActivityType catalogs

## CI Validation (GitLab)

The CI pipeline (`.gitlab-ci.yml`) includes three validation jobs:

- `validate:metadata`: runs `scripts/validate-metadata.py` over the tracked `metadata/` tree (no containers needed).
- `validate:seed`: runs `scripts/validate-demo-seed.py`, which checks the demo dataset is additive-only (every `DELETE` scoped to `demo-` rows), has no `TRUNCATE`, namespaces every row id, still totals the documented 38 rows, and that `--remove` covers every table the seed writes. Also fast and container-free.
- `blank_instance_check`: starts services, verifies DB access, and validates backup creation.

> The demo seed is **applied** locally and in the quickstart, not in CI: the `atro-web` image built by this pipeline starts Apache with a DocumentRoot that does not exist (the AtroCore application is never installed), so its schema never appears and there is nothing to seed. That is why the old `demo_seed_check` job skipped itself on every run.

Common CI variables you can override:

- `POSTGRES_PASSWORD`
- `POSTGRES_PIM_USER`
- `POSTGRES_PIM_PASSWORD`
- `POSTGRES_PIM_DB`
- `SKELETON_VARIANT`
- `BUILD_VARIANT`

## Troubleshooting

- Startup fails because of missing env vars: Ensure `.env` exists and required DB variables are set.
- Backup/restore scripts fail because DB is unavailable: Ensure the `db` container is running.
- Backup/restore scripts fail because of file path issues: Ensure dump file paths are correct.
- Port 80 already in use: Stop the conflicting service or change port mapping in Compose.

## Repository Structure

- `scripts/` - Backup, restore, demo seed, metadata install, and catalog seed helpers
- `metadata/` - Version-controlled AtroCore entity metadata (installed into `web-data/`)
- `sql/` - Reference-catalog and demo-dataset seed scripts (`seed-nomenclatura-catalog.sql`, `seed-demo-dataset.sql`, `seed-usoap-evidence-expectations.sql`)
- `db-dumps/` - Generated dump files (gitignored, never committed)
- `db-data/` - PostgreSQL persistent data
- `web-data/` - AtroCore web and application data

## License

This repository is licensed under the Apache License 2.0. See `LICENSE`.
Additional attribution details are provided in `NOTICE`.

Copyright (c) 2026 Fernando A. Casso Rodriguez.

License scope note:

- Unless otherwise stated, this license applies to the files maintained in this repository.
- Third-party software, dependencies, and upstream project files (for example bundled components under `web-data/`, including vendor packages) remain under their own respective licenses.

## Community

- Contribution guidelines: `CONTRIBUTING.md`
- Code of Conduct: `CODE_OF_CONDUCT.md`