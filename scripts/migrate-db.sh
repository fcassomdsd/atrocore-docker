#!/usr/bin/env bash
#
# Apply pending database migrations from sql/migrations/ in filename order.
#
# Convention
#   - One schema change per file, named NNNN_short_description.sql
#     (e.g. 0001_rename_protocolquestion_to_checklistquestion.sql).
#   - Applied files are recorded in the schema_migrations table and never re-run.
#   - sql/migrations/ is for DDL only. Reference data belongs in the seed
#     scripts (scripts/seed-*.sh), and entity metadata is installed separately
#     with scripts/install-metadata.sh followed by `console.php sql diff`.
#
# Ordering matters for metadata-coupled migrations: run this BEFORE
# scripts/install-metadata.sh when a migration renames entities the new metadata
# refers to (see metadata/README.md for the ChecklistQuestion rename).
#
# Usage:
#   scripts/migrate-db.sh --status   # list pending migrations, change nothing
#   scripts/migrate-db.sh --yes      # apply pending migrations
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
MIGRATIONS_DIR="${ROOT_DIR}/sql/migrations"

CONFIRMED="0"
STATUS_ONLY="0"

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED="1" ;;
    --status) STATUS_ONLY="1" ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: $0 [--status|--yes]" >&2
      exit 2
      ;;
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

if [[ ! -d "${MIGRATIONS_DIR}" ]]; then
  echo "No migrations directory at ${MIGRATIONS_DIR}; nothing to do."
  exit 0
fi

cd "${ROOT_DIR}"

psql_db() {
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "${POSTGRES_PIM_USER}" -d "${POSTGRES_PIM_DB}" "$@"
}

# Read-only check first: --status must not modify the database, so the
# bookkeeping table is only created when migrations are actually applied.
table_exists="$(psql_db -At -c "SELECT to_regclass('public.schema_migrations') IS NOT NULL;")"
applied=""
if [[ "${table_exists}" == "t" ]]; then
  applied="$(psql_db -At -c "SELECT filename FROM schema_migrations;")"
fi

pending=()
while IFS= read -r file; do
  name="$(basename "${file}")"
  if ! grep -qxF "${name}" <<<"${applied}"; then
    pending+=("${name}")
  fi
done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name '*.sql' | sort)

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "All migrations are up to date."
  exit 0
fi

echo "Pending migrations:"
for name in "${pending[@]}"; do
  echo "  - ${name}"
done

if [[ "${STATUS_ONLY}" == "1" ]]; then
  exit 0
fi

if [[ "${CONFIRMED}" != "1" ]]; then
  echo
  echo "This applies the migrations above to database ${POSTGRES_PIM_DB}."
  echo "Take a fresh backup first (./scripts/backup-db.sh)."
  echo "Run again with --yes to continue."
  exit 1
fi

echo "Ensuring schema_migrations exists in ${POSTGRES_PIM_DB}..."
psql_db -q -c "
  CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
"

for name in "${pending[@]}"; do
  file="${MIGRATIONS_DIR}/${name}"
  echo "Applying ${name}..."

  # File contents and the bookkeeping row commit together.
  {
    echo "BEGIN;"
    cat "${file}"
    printf "\nINSERT INTO schema_migrations (filename) VALUES ('%s') ON CONFLICT (filename) DO NOTHING;\n" "${name}"
    echo "COMMIT;"
  } | psql_db -q

  echo "  applied ${name}"
done

echo
echo "Migrations complete. If this changed entities the metadata refers to, run"
echo "scripts/install-metadata.sh next, then clear cache and review 'sql diff --show'."
