#!/usr/bin/env bash

# Seed the starter authority dataset (placeholder records) into the running
# AtroCore database.
#
# This is for an authority standing up its own deployment: a minimal set of
# Location / ServiceProvider / Person / Inspector / ServiceArea / AssignmentGroup /
# InspectionCadence / Reglamento / Normativa rows so the entities are visibly
# connected and can be edited into real data. It is NOT the demo dataset — the demo
# (`seed-demo-dataset.sh`) is synthetic ZZZZ data for the quickstart; use one or the
# other, not both.
#
# Run this AFTER the stack is up, the metadata installed and the schema applied,
# and after the reference catalogs (the starter rows reference spec_ats / atype_i):
#
#   docker compose up -d
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#   ./scripts/seed-nomenclatura.sh --yes     # provides spec_* / atype_*
#   ./scripts/seed-starter-dataset.sh --yes
#
# ADDITIVE and idempotent: every row's id starts with `starter-`, inserts use
# ON CONFLICT DO NOTHING, and nothing outside `starter-%` is ever touched — so an
# edit you make to a placeholder is never overwritten by a re-run.
#
# Usage:
#   scripts/seed-starter-dataset.sh --yes             # add the starter rows
#   scripts/seed-starter-dataset.sh --remove --yes    # delete every starter- row
#   scripts/seed-starter-dataset.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-starter-dataset.sql"

CONFIRMED="0"
REMOVE="0"
POSITIONAL=()

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED="1" ;;
    --remove) REMOVE="1" ;;
    *) POSITIONAL+=("${arg}") ;;
  esac
done

TARGET_DB="${POSITIONAL[0]:-}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found. Copy .env.example to .env and set database values first."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ -z "${POSTGRES_PIM_USER:-}" || -z "${POSTGRES_PIM_DB:-}" ]]; then
  echo "Error: POSTGRES_PIM_USER and POSTGRES_PIM_DB must be defined in .env."
  exit 1
fi

if [[ -z "${TARGET_DB}" ]]; then
  TARGET_DB="${POSTGRES_PIM_DB}"
fi

# Child rows first, so the order stays correct even if AtroCore ever starts
# declaring database-level foreign keys.
STARTER_TABLES=(
  normativa
  reglamento
  inspection_cadence
  location_service_specialty
  location_service
  inspector_specialty
  inspector
  person
  location
  service_provider
  service_area
  assignment_group
)

if [[ "${REMOVE}" == "1" ]]; then
  if [[ "${CONFIRMED}" != "1" ]]; then
    echo "This will DELETE every row whose id starts with 'starter-' in ${TARGET_DB} (${#STARTER_TABLES[@]} tables)."
    echo "Run again with --remove --yes to continue."
    exit 1
  fi

  cd "${ROOT_DIR}"
  echo "Removing the starter dataset from database ${TARGET_DB}..."

  REMOVE_SQL="BEGIN;"
  for table in "${STARTER_TABLES[@]}"; do
    REMOVE_SQL+=" DELETE FROM public.${table} WHERE id LIKE 'starter-%';"
  done
  # Join rows written through the Import module get generated ids, not `starter-` ones, so
  # remove them by their starter parent too. Otherwise `--remove` leaves an orphan link behind
  # and the next `--yes` aborts on the (parent, child) unique index in *_specialty.
  REMOVE_SQL+=" DELETE FROM public.inspector_specialty WHERE inspector_id LIKE 'starter-%';"
  REMOVE_SQL+=" DELETE FROM public.location_service_specialty WHERE location_service_id LIKE 'starter-%';"
  REMOVE_SQL+=" COMMIT;"

  printf '%s\n' "${REMOVE_SQL}" | docker compose exec -T db psql \
    -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_PIM_USER}" \
    -d "${TARGET_DB}"

  echo "Starter dataset removed. Nothing outside 'starter-%' was touched."
  exit 0
fi

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Error: seed script not found: ${SQL_FILE}"
  exit 1
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This will add placeholder authority records (ids starting with 'starter-') to database ${TARGET_DB}."
  echo "Existing rows are not modified. Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes | --remove --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding the starter authority dataset into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "Starter dataset seeded. Edit the '(editar)' values in the admin UI, then remove the rest with --remove."
