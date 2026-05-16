#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <dump-file> [target-db]"
  exit 1
fi

DUMP_FILE="$1"
TARGET_DB="${2:-}"

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

if [[ ! -f "${DUMP_FILE}" ]]; then
  if [[ -f "${ROOT_DIR}/${DUMP_FILE}" ]]; then
    DUMP_FILE="${ROOT_DIR}/${DUMP_FILE}"
  else
    echo "Error: dump file not found: $1"
    exit 1
  fi
fi

cd "${ROOT_DIR}"

echo "Restoring ${DUMP_FILE} into database ${TARGET_DB}..."
docker compose exec -T db pg_restore \
  -U "${POSTGRES_PIM_USER}" \
  -d "${TARGET_DB}" \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl < "${DUMP_FILE}"

echo "Restore completed."
