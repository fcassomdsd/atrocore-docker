#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DUMP_DIR="${ROOT_DIR}/db-dumps"

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

mkdir -p "${DUMP_DIR}"
TIMESTAMP="$(date +%F-%H%M%S)"
OUT_FILE="${DUMP_DIR}/atrocore-${TIMESTAMP}.dump"

cd "${ROOT_DIR}"

docker compose exec -T db pg_dump \
  -U "${POSTGRES_PIM_USER}" \
  -d "${POSTGRES_PIM_DB}" \
  -Fc > "${OUT_FILE}"

if [[ ! -s "${OUT_FILE}" ]]; then
  echo "Error: dump was created but is empty: ${OUT_FILE}"
  exit 1
fi

echo "Backup created: ${OUT_FILE}"
