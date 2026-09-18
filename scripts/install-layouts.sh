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
# relationships. The metadata/ layouts also carried `listDashlet` files, but that
# view type is not referenced anywhere in this AtroCore version and saveContent has
# no case for it -- writing it would store an EMPTY custom layout and hide the
# default -- so those files were removed rather than materialised.
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
  local entity="$1" view="$2" file="$3" related_scope="${4:-}"
  local url="${API_BASE}/${entity}/layout/${view}?layoutProfileId=${PROFILE_ID}"
  local label="${entity}/${view}"
  if [[ -n "${related_scope}" ]]; then
    url="${url}&relatedScope=${related_scope}"
    label="${entity}/${view} (${related_scope})"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  [dry-run] PUT %s\n' "${url}"
    return 0
  fi
  local status
  # The Layout route's OpenAPI security scheme is an apiKey header literally named
  # `Authorization-Token` (see Atro\Core\OpenApiGenerator: securitySchemes). Sending the
  # token as `Authorization: Bearer` answers HTTP 400 "None of security schemas did match";
  # the entity routes Node-RED uses accept Bearer, but this one does not.
  status="$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PUT \
    -H "Authorization-Token: ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${file}" "${url}")"
  if [[ "${status}" != "200" && "${status}" != "204" ]]; then
    echo "Error: PUT ${label} returned HTTP ${status}." >&2
    exit 1
  fi
  printf '  %s\n' "${label}"
}

echo "Materialising tracked layouts into profile '${PROFILE_ID}'..."
applied=0
for entity_dir in "${LAYOUTS_DIR}"/*/; do
  [[ -d "${entity_dir}" ]] || continue
  entity="$(basename "${entity_dir}")"
  for file in "${entity_dir%/}"/*.json; do
    [[ -f "${file}" ]] || continue
    base="$(basename "${file}" .json)"
    related_scope=""
    case "${base}" in
      list|detail|kanban|relationships)
        view="${base}"
        ;;
      # Related-scope layout, named the way LayoutManager::getLayoutFromFiles looks for it:
      # <view>In<RelatedEntity>For<Ucfirst(link)>. Recover the link's real case (link names
      # are camelCase, so only the first letter was upper-cased) and pass it as relatedScope,
      # which the API splits into relatedEntity/relatedLink.
      listIn*For*|detailIn*For*)
        view="${base%%In*}"
        rest="${base#*In}"
        rel_entity="${rest%%For*}"
        link_cap="${rest#*For}"
        link="$(printf '%s' "${link_cap:0:1}" | tr '[:upper:]' '[:lower:]')${link_cap:1}"
        related_scope="${rel_entity}.${link}"
        ;;
      *)
        echo "  skipping unrecognised layout file ${entity}/${base}.json" >&2
        continue
        ;;
    esac
    apply_view "${entity}" "${view}" "${file}" "${related_scope}"
    applied=$((applied + 1))
  done
done

echo "Layouts installed: ${applied} file(s) into profile '${PROFILE_ID}'."
