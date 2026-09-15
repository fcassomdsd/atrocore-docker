#!/usr/bin/env bash
#
# bootstrap-web-data.sh — put the AtroCore application into ./web-data/ on first run.
#
# WHY THIS EXISTS
# ---------------
# The atro-web image contains a fully installed AtroCore app at /var/www/<domain>:
# `prepare-pim.sh` clones the skeleton and writes its database config during the
# image build. But docker-compose.yaml bind-mounts ./web-data over /var/www/, and a
# bind mount does **not** inherit the image's content. On a clean clone ./web-data
# does not exist, so the empty host directory hides every baked-in file: Apache
# starts with a DocumentRoot that is not there, http://localhost serves nothing,
# and `scripts/install-metadata.sh` aborts because web-data/<domain>/data is missing.
# (It used to be a named volume — `web-data:/var/www/` — which Docker *does*
# populate from the image, so this only broke when the mount became a bind.)
#
# This copies the image's /var/www into ./web-data/ once, so the documented order
# (`docker compose up -d --build` → `install-metadata.sh` → seeds) actually works.
#
# It is idempotent: if web-data/<domain> already exists it does nothing. `--force`
# re-copies over an existing tree (destructive to local edits under web-data/).
#
# Usage: scripts/bootstrap-web-data.sh [--force]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
FORCE=0

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found — copy .env.example and fill it in first (runbook §4.1)." >&2
  exit 1
fi

cd "${ROOT_DIR}"

DOMAIN="localhost"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a
DOMAIN="${PRODUCTION_DOMAIN:-localhost}"
DEST="${ROOT_DIR}/web-data/${DOMAIN}"

if [[ -d "${DEST}" && "${FORCE}" != "1" ]]; then
  echo "bootstrap-web-data: web-data/${DOMAIN} already exists — nothing to do."
  exit 0
fi

# The service declares no `image:`, so Compose names the built image
# "<project>-atro-web"; `config --images` is the version-independent way to ask.
resolve_image() {
  docker compose config --images 2>/dev/null | grep -E '(^|[-_])atro-web$' | head -1 || true
}

IMAGE="$(resolve_image)"
if [[ -z "${IMAGE}" ]]; then
  echo "bootstrap-web-data: no atro-web image found — building it (this is the slow step) …"
  docker compose build atro-web
  IMAGE="$(resolve_image)"
fi

if [[ -z "${IMAGE}" ]]; then
  echo "Error: could not resolve the atro-web image name." >&2
  echo "Run 'docker compose build atro-web' and retry." >&2
  exit 1
fi

echo "bootstrap-web-data: copying the application from ${IMAGE} into web-data/ …"
mkdir -p "${ROOT_DIR}/web-data"

# Only ./web-data is mounted into this throwaway container. Mounting the service's
# own /var/www would hide the very files we are copying — that is the bug.
docker run --rm \
  -v "${ROOT_DIR}/web-data:/host" \
  --entrypoint sh \
  "${IMAGE}" \
  -c 'cp -a /var/www/. /host/'

if [[ ! -d "${DEST}" ]]; then
  echo "Error: expected ${DEST} after the copy, but it is missing." >&2
  exit 1
fi

echo "bootstrap-web-data: ok — web-data/${DOMAIN}/ created from the image."
echo "Next: ./scripts/install-metadata.sh"
