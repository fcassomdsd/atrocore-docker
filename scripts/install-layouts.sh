#!/usr/bin/env bash

# Install the platform's default layout profile and materialise the tracked
# layouts into it.
#
# WHY
# ---
# AtroCore loads layout *content* from the `layout` database table (per layout
# profile) or from the core/module resource trees -- never from `data/layouts/`,
# where install-metadata.sh copies `metadata/layouts/`. So the tracked layouts
# are inert until they are written into a profile, and the profile's `navigation`
# is what makes the entities reachable in the UI at all. This script does both:
#
#   1. sql/seed-layout-profile.sql  -- the `default` profile's menu/favourites
#   2. PUT /api/v1/<Entity>/layout/<view>?layoutProfileId=<id>  -- one call per
#      tracked layout file, using AtroCore's own normaliser
#
# Step 2 goes through the REST action rather than writing the layout child tables
# (layout_list_item / layout_section / layout_row_item / layout_relationship_item)
# directly, so the table mapping stays owned by AtroCore.
#
# Only view types Layout::saveContent can persist are sent: list, detail, kanban,
# relationships. `listDashlet` is skipped deliberately -- it has no case in
# saveContent, so writing it would create an EMPTY custom layout and hide the
# default; leaving it absent keeps AtroCore's own fallback for that view.
#
# PREREQUISITES: stack up, AtroCore installed, schema applied
# (install-metadata.sh + console.php clear cache + sql diff --run).
#
# Credentials: ATROCORE_USERNAME / ATROCORE_PASSWORD, read from this repo's .env
# or from ../compliance_flow/.env (where the platform keeps them); the
# environment wins if both are absent.
#
# Usage: scripts/install-layouts.sh [--yes] [--dry-run]
#   --yes      required: acknowledges that the profile's menu is overwritten
#   --dry-run  print the calls without applying them

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYOUTS_DIR="${ROOT_DIR}/metadata/layouts"
SQL_FILE="${ROOT_DIR}/sql/seed-layout-profile.sql"

CONFIRMED="0"
DRY_RUN="0"
for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED="1" ;;
    --dry-run) DRY_RUN="1" ;;
    *) echo "Unknown argument: ${arg}" >&2; echo "Usage: $0 [--yes] [--dry-run]" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- environment
# compliance_flow/.env first (AtroCore credentials live there), then this repo's
# .env (database/domain values). Later files win, but they do not define the
# AtroCore credentials, so the flow values survive.
for env_file in "${ROOT_DIR}/../compliance_flow/.env" "${ROOT_DIR}/.env"; do
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
done

DEMO_HOST="${DEMO_HOST:-localhost}"
# Resolve the host-reachable API base. ATROCORE_BASE_URL from compliance_flow/.env is the
# in-network URL (http://atro-web/api/v1) and is NOT reachable from the host, so it is
# deliberately not used here. Callers where AtroCore is not on localhost (e.g. the GitLab
# runner, which reaches it as http://docker) set ATROCORE_HOST_BASE or the full
# ATROCORE_API_BASE.
if [[ -n "${ATROCORE_API_BASE:-}" ]]; then
  API_BASE="${ATROCORE_API_BASE}"
else
  API_BASE="${ATROCORE_HOST_BASE:-http://${DEMO_HOST}}/api/v1"
fi
PROFILE_ID="${LAYOUT_PROFILE_ID:-default}"

if [[ -z "${ATROCORE_USERNAME:-}" || -z "${ATROCORE_PASSWORD:-}" ]]; then
  echo "Error: ATROCORE_USERNAME and ATROCORE_PASSWORD must be set (this repo's .env or ../compliance_flow/.env)." >&2
  exit 1
fi

if [[ ! -d "${LAYOUTS_DIR}" ]]; then
  echo "Error: ${LAYOUTS_DIR} not found." >&2
  exit 1
fi

if [[ "${CONFIRMED}" != "1" && "${DRY_RUN}" != "1" ]]; then
  echo "This action replaces the '${PROFILE_ID}' layout profile's menu and materialises the tracked layouts into it."
  echo "Run again with --yes to continue (or --dry-run to preview)."
  exit 1
fi

# --------------------------------------------------------- 1. profile / menu
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "[dry-run] would apply ${SQL_FILE} to database ${POSTGRES_PIM_DB:-<unset>}"
else
  if [[ -z "${POSTGRES_PIM_USER:-}" || -z "${POSTGRES_PIM_DB:-}" ]]; then
    echo "Error: POSTGRES_PIM_USER and POSTGRES_PIM_DB must be defined (this repo's .env)." >&2
    exit 1
  fi
  echo "Seeding the '${PROFILE_ID}' layout profile..."
  ( cd "${ROOT_DIR}" && docker compose exec -T db psql \
      -v ON_ERROR_STOP=1 \
      -U "${POSTGRES_PIM_USER}" \
      -d "${POSTGRES_PIM_DB}" < "${SQL_FILE}" )
fi

# ------------------------------------------------------------- 2. auth token
if [[ "${DRY_RUN}" == "1" ]]; then
  TOKEN="dry-run"
else
  echo "Authenticating to AtroCore at ${API_BASE}..."
  TOKEN="$(curl -s -m 30 -u "${ATROCORE_USERNAME}:${ATROCORE_PASSWORD}" "${API_BASE}/App/user" \
    | python3 -c 'import sys, json
try:
    print(json.load(sys.stdin).get("authorizationToken", ""))
except Exception:
    print("")')"
  if [[ -z "${TOKEN}" ]]; then
    echo "Error: could not obtain an AtroCore token from ${API_BASE}/App/user." >&2
    exit 1
  fi
fi

# ------------------------------------------------------- 3. materialise files
apply_view() {
  local entity="$1" view="$2" file="$3"
  local url="${API_BASE}/${entity}/layout/${view}?layoutProfileId=${PROFILE_ID}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  [dry-run] PUT %s (%s/%s.json)\n' "${url}" "${entity}" "${view}"
    return 0
  fi
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${file}" "${url}")"
  if [[ "${status}" != "200" && "${status}" != "204" ]]; then
    echo "Error: PUT ${entity}/layout/${view} returned HTTP ${status}." >&2
    exit 1
  fi
  printf '  %s/%s\n' "${entity}" "${view}"
}

echo "Materialising tracked layouts into profile '${PROFILE_ID}'..."
applied=0
skipped=0
for entity_dir in "${LAYOUTS_DIR}"/*/; do
  [[ -d "${entity_dir}" ]] || continue
  entity="$(basename "${entity_dir}")"
  for view in list detail kanban relationships; do
    file="${entity_dir%/}/${view}.json"
    if [[ -f "${file}" ]]; then
      apply_view "${entity}" "${view}" "${file}"
      applied=$((applied + 1))
    fi
  done
  if [[ -f "${entity_dir%/}/listDashlet.json" ]]; then
    skipped=$((skipped + 1))
  fi
done

echo "Layouts installed: ${applied} file(s) into profile '${PROFILE_ID}'; ${skipped} listDashlet file(s) skipped (not persistable by AtroCore's Layout::saveContent)."
