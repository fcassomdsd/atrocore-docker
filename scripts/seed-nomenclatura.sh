#!/usr/bin/env bash

# Seed the Nomenclatura reference catalogs (Specialty, ActivityType) into the
# running AtroCore database.
#
# Run this AFTER `docker compose up -d` and after AtroCore has applied the
# schema from web-data/<domain>/data/metadata/:
#
#   ./scripts/install-metadata.sh
#   docker compose exec atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec atro-web php /var/www/localhost/console.php sql diff --run
#
# That is what creates the `activity_type` table and the `activity_type_id`
# columns; this script only fills in the rows.
#
# DESTRUCTIVE: replaces every row in `specialty` and `activity_type`.
#
# Usage: scripts/seed-nomenclatura.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-nomenclatura-catalog.sql"

CONFIRMED="0"
POSITIONAL=()

for arg in "$@"; do
  if [[ "${arg}" == "--yes" ]]; then
    CONFIRMED="1"
  else
    POSITIONAL+=("${arg}")
  fi
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
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding Nomenclatura catalogs into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "Nomenclatura seed completed."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the new catalogs."
