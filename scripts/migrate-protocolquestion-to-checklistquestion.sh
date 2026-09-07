#!/usr/bin/env bash

# One-shot DB migration: rename the ProtocolQuestion entity's schema to
# ChecklistQuestion (2026-09 disambiguation from UsoapProtocolQuestion).
#
# This is a pure rename (ALTER TABLE/COLUMN/INDEX ... RENAME) -- no data is
# copied or lost, no ids change. Run it BEFORE installing the new
# ChecklistQuestion metadata, in this order:
#
#   ./scripts/backup-db.sh                                  # fresh safety net
#   ./scripts/migrate-protocolquestion-to-checklistquestion.sh --yes
#   ./scripts/install-metadata.sh
#   docker compose exec atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec atro-web php /var/www/localhost/console.php sql diff --show   # review
#   docker compose exec atro-web php /var/www/localhost/console.php sql diff --run
#
# Reversing the order (installing ChecklistQuestion metadata first) makes
# `sql diff` propose an empty duplicate `checklist_question` table alongside
# the still-existing `protocol_question` -- do not do that.
#
# Usage: scripts/migrate-protocolquestion-to-checklistquestion.sh --yes

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/rename-protocolquestion-to-checklistquestion.sql"

CONFIRMED="0"
for arg in "$@"; do
  if [[ "${arg}" == "--yes" ]]; then
    CONFIRMED="1"
  fi
done

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
  echo "Error: migration script not found: ${SQL_FILE}"
  exit 1
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This action renames protocol_question* / normativa_protocol_question / user_followed_protocol_question"
  echo "tables and inspection_question.protocol_question_id in database ${POSTGRES_PIM_DB} to their"
  echo "checklist_question* equivalents. Take a fresh backup first (./scripts/backup-db.sh)."
  echo "Run again with --yes to continue."
  echo "Usage: $0 --yes"
  exit 1
fi

cd "${ROOT_DIR}"

echo "Renaming ProtocolQuestion schema to ChecklistQuestion in database ${POSTGRES_PIM_DB}..."
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${POSTGRES_PIM_DB}" < "${SQL_FILE}"

echo "Rename completed."
echo "Next: ./scripts/install-metadata.sh, then clear cache + sql diff --show/--run (see script header)."
