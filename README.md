# Docker Compose configuration for AtroPIM

Deployment guide is available [here](https://help.atrocore.com/installation-and-maintenance/installation/docker-configuration).

## Preconfigured Docker Compose services 

- Apache HTTP server with PHP 8.2
- PostgreSQL 15
- Traefik v3.6 (optional)

## Database backup and restore

Create a backup dump file:

```bash
./scripts/backup-db.sh
```

The dump is written to `db-dumps/` with a timestamped name.

Restore a dump into the default database from `.env` (`POSTGRES_PIM_DB`):

```bash
./scripts/restore-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump
```

Restore into a specific database:

```bash
./scripts/restore-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump another_db_name
```

Notes:

- Ensure containers are running before backup/restore (`docker compose up -d`).
- Restore uses `--clean --if-exists`, which replaces existing objects in the target database.

## Demo data seed

Seed the default database from `atrocore.dump`:

```bash
./scripts/seed-demo-db.sh --yes
```

Seed from another dump file into a specific database:

```bash
./scripts/seed-demo-db.sh db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump another_db_name --yes
```

## Makefile shortcuts

Common tasks:

```bash
make up
make db-backup
make db-restore DUMP=db-dumps/atrocore-YYYY-MM-DD-HHMMSS.dump
make db-seed YES=1
```

Optional parameters:

- Restore to another database: `make db-restore DUMP=... DB=another_db_name`
- Seed from another dump: `make db-seed DUMP=db-dumps/file.dump DB=another_db_name YES=1`

## GitLab CI

This repository includes a pipeline at `.gitlab-ci.yml` with two validation jobs:

- `blank_instance_check`: builds and starts services, validates DB access, and verifies backup creation.
- `demo_seed_check`: builds and starts services, restores `atrocore.dump`, and verifies database tables exist.

You can override CI defaults using GitLab CI/CD variables:

- `POSTGRES_PASSWORD`
- `POSTGRES_PIM_USER`
- `POSTGRES_PIM_PASSWORD`
- `POSTGRES_PIM_DB`
- `SKELETON_VARIANT`
- `BUILD_VARIANT`