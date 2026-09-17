#!/usr/bin/env bash
#
# bootstrap-web-data.sh — install AtroCore into ./web-data/ on first run.
#
# WHY THIS EXISTS
# ---------------
# docker-compose.yaml bind-mounts ./web-data over /var/www, and a bind mount does **not**
# inherit whatever an image build would otherwise put there — a clean clone's empty
# ./web-data hides anything baked into the image at that path.
#
# AtroCore has no official pre-built Docker image the way Alfresco does: its own
# distribution model is "clone a skeleton repo, run Composer/its installer," so *some*
# install step is unavoidable. This script is that step. It used to be unnecessary because
# the atro-web image baked the install into its own build layers (`.docker/php/Dockerfile`
# used to run `.docker/php/scripts/prepare-pim.sh` at `docker build` time) — but AtroCore's
# core packages are GPL-3.0-only, and installing them at build time means any pre-built copy
# of that image carries GPL-3.0 source, which "distribution" obligations attach to. This
# script runs the exact same install sequence instead, at first `docker compose up`, inside a
# throwaway container built from the (now install-free) image, writing the result straight
# into the bind-mounted ./web-data/ — so the atro-web image itself never contains AtroCore's
# source in any layer, only the generic PHP+Apache base.
#
# It is idempotent: if web-data/<domain> already exists it does nothing (prepare-pim.sh,
# which this script invokes, has the same check independently). `--force` re-runs the
# install over an existing tree (destructive to local edits under web-data/).
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

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

SKELETON_VARIANT="${SKELETON_VARIANT:-pim-no-demo}"
PRODUCTION_DOMAIN="${PRODUCTION_DOMAIN:-localhost}"
PRODUCTION_STABILITY="${PRODUCTION_STABILITY:-stable}"
TESTING_DOMAIN="${TESTING_DOMAIN:-}"
TESTING_STABILITY="${TESTING_STABILITY:-stable}"

DEST="${ROOT_DIR}/web-data/${PRODUCTION_DOMAIN}"

if [[ -d "${DEST}" && "${FORCE}" != "1" ]]; then
  echo "bootstrap-web-data: web-data/${PRODUCTION_DOMAIN} already exists — nothing to do."
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

echo "bootstrap-web-data: installing AtroCore (pulls from AtroCore's own upstream — needs network access) …"
mkdir -p "${ROOT_DIR}/web-data"

# Deliberately do NOT bind-mount ./web-data over /var/www here — that would hide this
# image's own /var/www/scripts the same way it hides an installed app in the real service,
# and prepare-pim.sh's own internal references assume scripts/ is a sibling of /var/www's
# installed app. Instead: run the install against the image's native (throwaway-container-
# local) /var/www, then copy the freshly-installed result out to ./web-data/, the same way
# this script always has.
docker run --rm \
  -v "${ROOT_DIR}/web-data:/host" \
  -e SKELETON_VARIANT="${SKELETON_VARIANT}" \
  -e PRODUCTION_DOMAIN="${PRODUCTION_DOMAIN}" \
  -e PRODUCTION_STABILITY="${PRODUCTION_STABILITY}" \
  -e TESTING_DOMAIN="${TESTING_DOMAIN}" \
  -e TESTING_STABILITY="${TESTING_STABILITY}" \
  -e POSTGRES_PIM_USER="${POSTGRES_PIM_USER:-}" \
  -e POSTGRES_PIM_PASSWORD="${POSTGRES_PIM_PASSWORD:-}" \
  -e POSTGRES_PIM_DB="${POSTGRES_PIM_DB:-}" \
  -e POSTGRES_PIM_DB_TEST="${POSTGRES_PIM_DB_TEST:-}" \
  --entrypoint bash \
  "${IMAGE}" \
  -c '
    set -e
    cd /var/www
    ./scripts/prepare-pim.sh --optional "$SKELETON_VARIANT" "$TESTING_STABILITY" "$TESTING_DOMAIN" "$POSTGRES_PIM_USER" "$POSTGRES_PIM_PASSWORD" "$POSTGRES_PIM_DB_TEST"
    ./scripts/prepare-pim.sh "$SKELETON_VARIANT" "$PRODUCTION_STABILITY" "$PRODUCTION_DOMAIN" "$POSTGRES_PIM_USER" "$POSTGRES_PIM_PASSWORD" "$POSTGRES_PIM_DB"
    mkdir -p /var/www/.cache && chown www-data:www-data /var/www/.cache
    # scripts/ is install tooling, not part of the app — drop it from this (throwaway,
    # --rm) container before copying out, so it never lands in web-data/. This mirrors
    # the old build-time behavior, which never had scripts/ present at this point either
    # (the Dockerfile used to `rm -rf` it in the same RUN step that ran the install).
    rm -rf /var/www/scripts
    cp -a /var/www/. /host/
  '

if [[ ! -d "${DEST}" ]]; then
  echo "Error: expected ${DEST} after install, but it is missing." >&2
  exit 1
fi

echo "bootstrap-web-data: ok — web-data/${PRODUCTION_DOMAIN}/ installed."
echo "Next: ./scripts/install-metadata.sh"
