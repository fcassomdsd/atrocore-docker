# AtroCore Docker Environment

Docker Compose setup for running AtroCore/AtroPIM locally with:

- Apache + PHP 8.2 (`atro-web` service)
- PostgreSQL 15 (`db` service)
- Optional Traefik reverse proxy (via the provided example override file)

Official deployment documentation: https://help.atrocore.com/installation-and-maintenance/installation/docker-configuration

## Quick Start

### First 5 Minutes Checklist

Use this checklist if you are running the project for the first time:

1. Copy `.env.example` to `.env`.
2. Fill in database credentials in `.env`.
3. Start containers with `docker compose up -d --build`.
4. Wait until `db` and `atro-web` are healthy/running in `docker compose ps`.
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

Seed the default database from `atrocore.dump`:

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

## Optional Traefik Reverse Proxy

This repository includes examples for Traefik in:

- `docker-compose.override.yaml.old`
- `traefik.yml.old`

If you want HTTPS and host-based routing, adapt these files to your setup and enable the related environment variables in `.env` (for example `LETS_ENCRYPT_EMAIL` and router names).

## Makefile Targets

Run `make help` to list all available shortcuts.

Main targets:

- `make up` - Start containers
- `make down` - Stop containers
- `make db-backup` - Create database backup
- `make db-restore DUMP=... [DB=...]` - Restore dump into DB
- `make db-seed [DUMP=atrocore.dump] [DB=...] YES=1` - Seed demo data

## CI Validation (GitLab)

The CI pipeline (`.gitlab-ci.yml`) includes two validation jobs:

- `blank_instance_check`: starts services, verifies DB access, and validates backup creation.
- `demo_seed_check`: starts services, seeds demo data, and verifies that public tables exist.

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

- `scripts/` - Backup, restore, and demo seed helpers
- `db-dumps/` - Generated dump files
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