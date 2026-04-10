#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DUMP="${ROOT_DIR}/atrocore.dump"

CONFIRMED="0"
POSITIONAL=()

for arg in "$@"; do
  if [[ "${arg}" == "--yes" ]]; then
    CONFIRMED="1"
  else
    POSITIONAL+=("${arg}")
  fi
done

DUMP_FILE="${POSITIONAL[0]:-${DEFAULT_DUMP}}"
TARGET_DB="${POSITIONAL[1]:-}"

if [[ ! -f "${DUMP_FILE}" ]]; then
  if [[ -f "${ROOT_DIR}/${DUMP_FILE}" ]]; then
    DUMP_FILE="${ROOT_DIR}/${DUMP_FILE}"
  else
    echo "Error: demo dump file not found: ${DUMP_FILE}"
    exit 1
  fi
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This action will REPLACE data in the target database."
  echo "Run again with --yes to continue."
  echo "Usage: $0 [dump-file] [target-db] --yes"
  exit 1
fi

if [[ -n "${TARGET_DB}" ]]; then
  "${ROOT_DIR}/scripts/restore-db.sh" "${DUMP_FILE}" "${TARGET_DB}"
else
  "${ROOT_DIR}/scripts/restore-db.sh" "${DUMP_FILE}"
fi

echo "Demo seed completed from: ${DUMP_FILE}"
