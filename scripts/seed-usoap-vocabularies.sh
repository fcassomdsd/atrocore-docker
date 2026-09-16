#!/usr/bin/env bash

# Seed the USOAP / risk extensible-enum vocabularies into the running AtroCore
# database.
#
# These vocabularies are REQUIRED INFRASTRUCTURE, not demo data: the tracked
# entity definitions in metadata/entityDefs/ reference them by hard-coded id
# (ChecklistQuestion.riskLevel, UsoapProtocolQuestion.criticalElement and
# .areaCode), and AtroCore's extensible enums have no home in metadata/ — so
# without this seed a fresh install cannot resolve a checklist question's risk
# level or its USOAP Critical Element / area at all.
#
# Run this AFTER the AtroCore schema exists and BEFORE seeding the demo dataset:
#
#   docker compose up -d
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#   ./scripts/seed-usoap-vocabularies.sh --yes
#   ./scripts/seed-nomenclatura.sh --yes
#   ./scripts/seed-demo-dataset.sh --yes
#
# ADDITIVE and NON-DESTRUCTIVE: it only INSERTs, with ON CONFLICT DO NOTHING, so
# it never overwrites vocabularies a deployment has already customised. It is
# deliberately NOT removed by seed-demo-dataset.sh --remove.
#
# Usage: scripts/seed-usoap-vocabularies.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-usoap-vocabularies.sql"

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
  echo "This will add the USOAP / risk extensible-enum vocabularies to database ${TARGET_DB}."
  echo "Existing enums and options are not modified (INSERT ... ON CONFLICT DO NOTHING)."
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding USOAP / risk vocabularies into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "Vocabularies seeded."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the enums."
