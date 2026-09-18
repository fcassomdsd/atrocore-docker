#!/usr/bin/env bash

# Enable the es_DO language so the controlled vocabularies carry Spanish labels, and seed them.
#
# WHY
# ---
# AtroCore only creates a multilingual field's sibling columns (name_es_do for a field named
# `name`) once a second language is configured as "additional". The reference
# Dominican-Republic deployment had that, so its `compliance`, `findingClass` and
# `inspectorRoles` dropdowns read Cumple / Categoría A / Inspector Principal. A fresh install
# has only `en_US` (role `main`) and therefore no such column, which is why the debt analysis
# recorded "two vocabularies have no Spanish labels on a fresh instance".
#
# WHAT IT DOES
#   1. adds `es_DO` (role `additional`) to data/reference-data/Language.json, idempotently —
#      Config derives `inputLanguageList`/`isMultilangActive` from that file;
#   2. `clear cache` + `sql diff --run` so AtroCore adds the name_es_do columns;
#   3. applies sql/seed-vocabulary-translations.sql (the labels).
#
# PREREQUISITES: stack up, metadata installed, schema applied
# (install-metadata.sh + clear cache + sql diff --run), and the vocabulary seed run
# (`./scripts/seed-usoap-vocabularies.sh --yes`) so the options exist.
#
# Idempotent: re-running adds nothing and only re-applies the same labels.
#
# Usage: scripts/enable-spanish-labels.sh [--yes]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SQL_FILE="${ROOT_DIR}/sql/seed-vocabulary-translations.sql"

CONFIRMED="0"
for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED="1" ;;
    *) echo "Unknown argument: ${arg}" >&2; echo "Usage: $0 [--yes]" >&2; exit 1 ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found. Copy .env.example to .env and set database values first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ -z "${POSTGRES_PIM_USER:-}" || -z "${POSTGRES_PIM_DB:-}" ]]; then
  echo "Error: POSTGRES_PIM_USER and POSTGRES_PIM_DB must be defined in .env." >&2
  exit 1
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo "This configures es_DO as an additional AtroCore language and applies the Spanish vocabulary labels."
  echo "Run again with --yes to continue."
  exit 1
fi

DOMAIN="${PRODUCTION_DOMAIN:-localhost}"

cd "${ROOT_DIR}"

# ------------------------------------------------- 1. add es_DO as an additional language
echo "Configuring es_DO as an additional language…"
docker compose exec -T -u www-data atro-web php -r '
$path = "/var/www/'"${DOMAIN}"'/data/reference-data/Language.json";
$data = json_decode(@file_get_contents($path), true);
if (!is_array($data)) {
    fwrite(STDERR, "Error: could not read {$path}\n");
    exit(1);
}
if (isset($data["es_DO"])) {
    echo "  es_DO already present\n";
    exit(0);
}
$data["es_DO"] = [
    "id"        => "es_do",
    "name"      => "Español (República Dominicana)",
    "code"      => "es_DO",
    "role"      => "additional",
    "createdAt" => date("Y-m-d H:i:s"),
];
if (file_put_contents($path, json_encode($data)) === false) {
    fwrite(STDERR, "Error: could not write {$path}\n");
    exit(1);
}
echo "  es_DO added\n";
'

# ------------------------------------------------------- 2. reload metadata and schema
echo "Clearing cache and syncing the schema so the name_es_do columns exist…"
docker compose exec -T -u www-data atro-web php "/var/www/${DOMAIN}/console.php" clear cache >/dev/null
docker compose exec -T -u www-data atro-web php "/var/www/${DOMAIN}/console.php" sql diff --run >/dev/null

# ------------------------------------------------------------------- 3. seed the labels
echo "Seeding the Spanish vocabulary labels…"
docker compose exec -T db psql \
  -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_PIM_USER}" \
  -d "${POSTGRES_PIM_DB}" < "${SQL_FILE}"

echo "Spanish labels enabled."
