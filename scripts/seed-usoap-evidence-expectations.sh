#!/usr/bin/env bash

# Seed the UsoapEvidenceExpectation catalog into the running AtroCore database.
#
# Run this AFTER `docker compose up -d` and after AtroCore has applied the
# schema from web-data/<domain>/data/metadata/ (see metadata/README.md):
#
#   ./scripts/install-metadata.sh
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#
# That is what creates the `usoap_evidence_expectation` table; this script
# only fills in rows. It also requires the UsoapProtocolQuestion catalog to
# already be imported (rows are matched to their parent PQ by `code`).
#
# DESTRUCTIVE: replaces every row in `usoap_evidence_expectation` and re-syncs
# the `usoap_artifact_category` extensible-enum options.
#
# Usage: scripts/seed-usoap-evidence-expectations.sh [target-db] --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-usoap-evidence-expectations.sql"

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
  echo "This action will REPLACE all rows in 'usoap_evidence_expectation' in database ${TARGET_DB}."
  echo "Run again with --yes to continue."
  echo "Usage: $0 [target-db] --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Seeding UsoapEvidenceExpectation catalog into database ${TARGET_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" < "${SQL_FILE}"

echo "USOAP evidence-expectation seed completed."
echo "Reminder: clear the AtroCore cache (Administration > Clear Cache) so the UI picks up the new catalog."
