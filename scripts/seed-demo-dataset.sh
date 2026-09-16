#!/usr/bin/env bash

# Seed the synthetic demo dataset into the running AtroCore database.
#
# Run this AFTER the stack is up and after AtroCore has applied the schema from
# the JSON metadata (see metadata/README.md), and after the reference catalogs:
#
#   docker compose up -d
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#   ./scripts/seed-nomenclatura.sh --yes          # provides spec_* / atype_*
#   ./scripts/seed-demo-dataset.sh --yes
#
# What it creates: one fictional airport, two service providers, three
# inspectors, their services and specialties, two site visits (one a month back
# for the finding/closure walkthrough, one three weeks out for planning), three
# inspections and their interview schedules. Enough to walk the whole workflow
# on a fresh install instead of staring at empty tables.
#
# ADDITIVE: unlike the catalog seeds, this one never truncates a table. It
# deletes and re-inserts only rows whose id starts with `demo-`, so it is safe
# against a database that already holds real records, and it is re-runnable.
#
# The whole dataset is synthetic (ICAO `ZZZZ`, `.invalid` e-mail addresses,
# invented names) and contains no credentials. Never put real authority data in
# sql/seed-demo-dataset.sql.
#
# Usage:
#   scripts/seed-demo-dataset.sh --yes             # add or refresh the demo rows
#   scripts/seed-demo-dataset.sh --remove --yes    # delete every demo- row
#   scripts/seed-demo-dataset.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-demo-dataset.sql"

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

# Child rows first so the order stays correct even if AtroCore ever starts
# declaring database-level foreign keys.
DEMO_TABLES=(
  inspection_question
  usoap_protocol_question_acapite_o_a_c_i
  normativa_checklist_question
  usoap_protocol_question
  normativa
  reglamento
  acapite_o_a_c_i
  documento_o_a_c_i
  checklist_question
  question_topic
  inspection_schedule
  inspected_specialty_inspector
  inspected_specialty
  inspected_service
  inspection
  inspected_provider
  site_visit
  location_service_specialty
  location_service
  inspector_specialty
  inspector
  person
  location
  service_provider
  service_area
)

if [[ "${REMOVE}" == "1" ]]; then
  if [[ "${CONFIRMED}" != "1" ]]; then
    echo "This will DELETE every row whose id starts with 'demo-' in ${TARGET_DB} (${#DEMO_TABLES[@]} tables)."
    echo "Run again with --remove --yes to continue."
    exit 1
  fi

  cd "${ROOT_DIR}"
  echo "Removing the synthetic demo dataset from database ${TARGET_DB}..."

  REMOVE_SQL="BEGIN;"
  for table in "${DEMO_TABLES[@]}"; do
    REMOVE_SQL+=" DELETE FROM public.${table} WHERE id LIKE 'demo-%';"
  done
  REMOVE_SQL+=" COMMIT;"

  printf '%s\n' "${REMOVE_SQL}" | docker compose exec -T db psql \
    -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_PIM_USER}" \
    -d "${TARGET_DB}"

  echo "Demo dataset removed. Nothing outside 'demo-%' was touched."
  exit 0
fi

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Error: seed script not found: ${SQL_FILE}"
  exit 1
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This will add or refresh the synthetic demo dataset (ids starting with 'demo-') in database ${TARGET_DB}."
  echo "Existing non-demo rows are not touched."
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes | --remove --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding the demo dataset into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "Demo dataset seeded."
echo "Site visits are dated relative to today (one a month back, one three weeks out); their"
echo "year-bearing codes use the current year."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the new records."
