#!/usr/bin/env bash

# Seed the ICAO reference-data catalog (Annex documents, Annex paragraphs and
# USOAP Protocol Questions) into the running AtroCore database.
#
# This is REQUIRED INFRASTRUCTURE for the USOAP citation chain, not demo data:
# `sql/seed-usoap-evidence-expectations.sql` resolves each row's parent
# Protocol Question by `code`, which silently resolves to NULL on a fresh
# install until this seed runs. Unlike `Normativa` (a specific country's
# national regulation — never seeded here; each adopting authority enters its
# own), everything this script loads is ICAO-standard content any State
# running a USOAP-aligned oversight programme needs.
#
# Run this AFTER the AtroCore schema exists and the USOAP/risk vocabularies,
# BEFORE the nomenclatura catalog and the demo dataset:
#
#   docker compose up -d
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#   ./scripts/seed-usoap-vocabularies.sh --yes
#   ./scripts/seed-icao-reference-data.sh --yes
#   ./scripts/seed-nomenclatura.sh --yes
#   ./scripts/seed-demo-dataset.sh --yes
#
# ADDITIVE and NON-DESTRUCTIVE: it only INSERTs, with ON CONFLICT DO NOTHING, so
# it never overwrites a deployment that already has this catalog (or has
# customised/extended it). It is deliberately NOT removed by
# seed-demo-dataset.sh --remove.
#
# Usage: scripts/seed-icao-reference-data.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-icao-reference-data.sql"

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

if [[ -z "${TARGET_DB}" ]]; then
  TARGET_DB="${POSTGRES_PIM_DB}"
fi

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Error: seed script not found: ${SQL_FILE}"
  exit 1
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This will add the ICAO reference-data catalog (15 Annex documents, 1,890 Annex"
  echo "paragraphs, 281 USOAP Protocol Questions, 439 citations) to database ${TARGET_DB}."
  echo "Existing rows are not modified (INSERT ... ON CONFLICT DO NOTHING)."
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding ICAO reference-data catalog into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "ICAO reference-data catalog seeded."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the new records."
