#!/usr/bin/env bash

# Install this repo's tracked AtroCore metadata into the running instance.
#
# WHY THIS EXISTS
# ---------------
# `web-data/` is gitignored and disposable: it is created by the atro-web
# container from the AtroCore skeleton, and CI literally does `rm -rf web-data`
# before every job. Anything edited directly under web-data/ is therefore
# unversioned and lost on the next clean build.
#
# So the version-controlled source of truth for our customisations lives in
# `metadata/` at the repo root, mirroring the layout AtroCore expects:
#
#   metadata/entityDefs/*.json  ->  web-data/<domain>/data/metadata/entityDefs/
#   metadata/clientDefs/*.json  ->  web-data/<domain>/data/metadata/clientDefs/
#   metadata/scopes/*.json      ->  web-data/<domain>/data/metadata/scopes/
#   metadata/layouts/<Entity>/  ->  web-data/<domain>/data/layouts/<Entity>/
#
# This script copies them across and registers new entities in config.php.
#
# AFTER RUNNING: make AtroCore pick up the model changes, then seed the
# reference rows. This AtroCore build has no `rebuild` console command; the
# equivalent is `clear cache` followed by `sql diff`:
#
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --show
#   docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
#   ./scripts/seed-nomenclatura.sh --yes
#
# Review the `--show` output before `--run`: it is the exact DDL AtroCore
# derives from the JSON, drops included.
#
# Usage: scripts/install-metadata.sh [--dry-run]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SRC_DIR="${ROOT_DIR}/metadata"

DRY_RUN="0"
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN="1" ;;
    *) echo "Unknown argument: ${arg}"; exit 1 ;;
  esac
done

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: metadata source directory not found: ${SRC_DIR}"
  exit 1
fi

DOMAIN="localhost"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  DOMAIN="${PRODUCTION_DOMAIN:-localhost}"
fi

DEST_ROOT="${ROOT_DIR}/web-data/${DOMAIN}/data"

if [[ ! -d "${DEST_ROOT}" ]]; then
  # A clean clone has no web-data/ at all: the compose bind mount hides the
  # AtroCore app the image was built with (see bootstrap-web-data.sh). Populate it
  # once, then re-check, so `up -> metadata-install` works as documented.
  echo "web-data/${DOMAIN} is missing — bootstrapping the AtroCore application from the image …"
  "${ROOT_DIR}/scripts/bootstrap-web-data.sh"
fi

if [[ ! -d "${DEST_ROOT}" ]]; then
  echo "Error: ${DEST_ROOT} not found." >&2
  echo "Run ./scripts/bootstrap-web-data.sh (it copies the app out of the atro-web image)." >&2
  exit 1
fi

# web-data is owned by www-data (uid 33) inside the container, so a plain `cp`
# from the host user may hit EACCES. Route the copy through a throwaway
# container running as root when we cannot write directly.
copy_file() {
  local src="$1" dest="$2"
  local dest_dir
  dest_dir="$(dirname "${dest}")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] ${src#"${ROOT_DIR}/"} -> ${dest#"${ROOT_DIR}/"}"
    return 0
  fi

  if mkdir -p "${dest_dir}" 2>/dev/null && cp "${src}" "${dest}" 2>/dev/null; then
    echo "  ${dest#"${ROOT_DIR}/"}"
    return 0
  fi

  docker run --rm \
    -v "${ROOT_DIR}:/repo" \
    -w /repo \
    alpine:3 \
    sh -c "mkdir -p '${dest_dir#"${ROOT_DIR}/"}' && cp '${src#"${ROOT_DIR}/"}' '${dest#"${ROOT_DIR}/"}' && chown 33:33 '${dest#"${ROOT_DIR}/"}' && chmod 664 '${dest#"${ROOT_DIR}/"}'"
  echo "  ${dest#"${ROOT_DIR}/"} (via container, root)"
}

remove_file() {
  local target="$1"
  [[ -e "${target}" ]] || return 0

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] remove ${target#"${ROOT_DIR}/"}"
    return 0
  fi

  if rm -f "${target}" 2>/dev/null; then
    echo "  removed ${target#"${ROOT_DIR}/"}"
    return 0
  fi

  docker run --rm -v "${ROOT_DIR}:/repo" -w /repo alpine:3 \
    sh -c "rm -f '${target#"${ROOT_DIR}/"}'"
  echo "  removed ${target#"${ROOT_DIR}/"} (via container, root)"
}

echo "Installing metadata into ${DEST_ROOT}"

for kind in entityDefs clientDefs scopes; do
  [[ -d "${SRC_DIR}/${kind}" ]] || continue
  echo "${kind}:"
  for f in "${SRC_DIR}/${kind}"/*.json; do
    [[ -e "$f" ]] || continue
    copy_file "$f" "${DEST_ROOT}/metadata/${kind}/$(basename "$f")"
  done
done

if [[ -d "${SRC_DIR}/layouts" ]]; then
  echo "layouts:"
  for entity_dir in "${SRC_DIR}/layouts"/*/; do
    [[ -d "${entity_dir}" ]] || continue
    entity="$(basename "${entity_dir}")"
    for f in "${entity_dir}"*.json; do
      [[ -e "$f" ]] || continue
      copy_file "$f" "${DEST_ROOT}/layouts/${entity}/$(basename "$f")"
    done
  done
fi

# Specialty is no longer a Hierarchy entity, so its hierarchy relationship
# panel layout must go or the UI will try to render the removed `children`
# link.
#
# ProtocolQuestion was renamed to ChecklistQuestion (2026-09): its old
# runtime-only metadata (never tracked here) must be removed so `sql diff`
# doesn't see two entity definitions pointing at the same physical table.
# This must run in the same maintenance window as the DB rename migration
# (see scripts/migrate-db.sh and sql/migrations/).
echo "stale layouts:"
remove_file "${DEST_ROOT}/layouts/Specialty/relationships.json"

echo "stale metadata (ProtocolQuestion -> ChecklistQuestion rename):"
remove_file "${DEST_ROOT}/metadata/entityDefs/ProtocolQuestion.json"
remove_file "${DEST_ROOT}/metadata/clientDefs/ProtocolQuestion.json"
remove_file "${DEST_ROOT}/metadata/scopes/ProtocolQuestion.json"
for f in "${DEST_ROOT}/layouts/ProtocolQuestion"/*.json; do
  [[ -e "$f" ]] || continue
  remove_file "$f"
done

# Register new entities in config.php (tabList + quickCreateList).
CONFIG_FILE="${DEST_ROOT}/config.php"
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "config.php: registering ActivityType, UsoapEvidenceExpectation, ChecklistQuestion"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] would append 'ActivityType', 'UsoapEvidenceExpectation', 'ChecklistQuestion' to tabList and quickCreateList"
    echo "  [dry-run] would remove 'ProtocolQuestion' from tabList and quickCreateList"
  else
    # config.php is owned by www-data, so edit a host-side temp copy and then
    # move it back through a root container (same reason as copy_file above).
    #
    # The temp copy is staged in the repository root — a place the host user can
    # write *and* the Docker daemon can see — rather than /tmp: on Docker
    # Desktop/Colima-style setups /tmp is not one of the shared paths, so
    # bind-mounting a file from there hands the container an empty *directory* and
    # `cp` fails with "can't stat '.../config.php/config.php': Not a directory".
    # (web-data/ cannot be used for this: it belongs to uid 33, so mktemp there is
    # Permission denied.) The trap removes it; .gitignore covers a crash.
    TMP_CONFIG="$(mktemp "${ROOT_DIR}/.config.php.XXXXXX")"
    trap 'rm -f "${TMP_CONFIG}"' EXIT

    # Read through a root container if the host user cannot read the file.
    if ! ( cat "${CONFIG_FILE}" > "${TMP_CONFIG}" ) 2>/dev/null; then
      docker run --rm -v "${ROOT_DIR}:/repo" -w /repo alpine:3 \
        cat "${CONFIG_FILE#"${ROOT_DIR}/"}" > "${TMP_CONFIG}"
    fi

    python3 "${ROOT_DIR}/scripts/register-entity-tab.py" "${TMP_CONFIG}" ActivityType UsoapEvidenceExpectation ChecklistQuestion
    python3 "${ROOT_DIR}/scripts/register-entity-tab.py" --remove "${TMP_CONFIG}" ProtocolQuestion

    if ! ( cat "${TMP_CONFIG}" > "${CONFIG_FILE}" ) 2>/dev/null; then
      docker run --rm \
        -v "${ROOT_DIR}:/repo" \
        -w /repo \
        alpine:3 \
        sh -c "cp '${TMP_CONFIG#"${ROOT_DIR}/"}' '${CONFIG_FILE#"${ROOT_DIR}/"}' && chown 33:33 '${CONFIG_FILE#"${ROOT_DIR}/"}' && chmod 664 '${CONFIG_FILE#"${ROOT_DIR}/"}'"
      echo "  config.php written (via container, root)"
    fi
  fi
else
  echo "Warning: ${CONFIG_FILE} not found; skipping tab registration."
fi

echo
echo "Metadata installed. Next steps:"
echo "  docker compose exec -u www-data atro-web php /var/www/${DOMAIN}/console.php clear cache"
echo "  docker compose exec -u www-data atro-web php /var/www/${DOMAIN}/console.php sql diff --show   # review"
echo "  docker compose exec -u www-data atro-web php /var/www/${DOMAIN}/console.php sql diff --run    # apply"
echo "  ./scripts/seed-nomenclatura.sh --yes"
