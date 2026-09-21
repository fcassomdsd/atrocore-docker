#!/usr/bin/env bash

# Seed the reference catalogs (Specialty, ActivityType, FindingSeverity) into
# the running AtroCore database.
#
# Run this AFTER `docker compose up -d` and after AtroCore has applied the
# schema from web-data/<domain>/data/metadata/:
#
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#
# That is what creates the `activity_type` and `finding_severity` tables and the
# `activity_type_id` columns; this script only fills in the rows.
#
# DESTRUCTIVE for `specialty` and `activity_type` (rows are replaced). FindingSeverity
# is upserted instead, so an administrator's tuned day counts are preserved.
#
# The specialty catalog is CAA-specific, so the default is only the three the
# demo and starter datasets reference (ATS, NAV, MET). Pass --full-specialties
# to also load the reference sixteen-taxonomy as a starting point.
#
# Usage: scripts/seed-nomenclatura.sh [target-db] --yes [--full-specialties]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-nomenclatura-catalog.sql"

CONFIRMED="0"
FULL_SPECIALTIES="0"
POSITIONAL=()

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED="1" ;;
    --full-specialties) FULL_SPECIALTIES="1" ;;
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

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Error: seed script not found: ${SQL_FILE}"
  exit 1
fi

if [[ -z "${TARGET_DB}" ]]; then
  TARGET_DB="${POSTGRES_PIM_DB}"
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This action will REPLACE all rows in 'specialty' and 'activity_type' in database ${TARGET_DB}."
  if [[ "${FULL_SPECIALTIES}" == "1" ]]; then
    echo "Specialties: the full reference sixteen (--full-specialties)."
  else
    echo "Specialties: the three default rows the demo/starter datasets use (ATS, NAV, MET)."
  fi
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes [--full-specialties]"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding Nomenclatura catalogs into database ${TARGET_DB}..."
PSQL_VARS=(-v ON_ERROR_STOP=1)
if [[ "${FULL_SPECIALTIES}" == "1" ]]; then
  PSQL_VARS+=(-v full_specialties=1)
fi
docker compose exec -T db psql \
  "${PSQL_VARS[@]}" \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "Nomenclatura seed completed."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the new catalogs."
