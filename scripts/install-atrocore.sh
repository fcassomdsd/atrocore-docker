#!/usr/bin/env bash
#
# install-atrocore.sh — complete the AtroCore installation on a freshly scaffolded instance.
#
# WHY THIS EXISTS
# ---------------
# `docker compose up -d --build` scaffolds the application *files* but does not install the
# application. A fresh instance has `'isInstalled' => false` in `data/config.php` and an empty
# `user` table, so `/api/v1/App/user` answers HTTP 500 and every consumer sees an unusable
# AtroCore: `compliance_flow`'s `/specialties` answers 400, `compliance_web` login fails, and
# `/inspectionPlan` cannot resolve anything. The scaffold is not the installation.
#
# AtroCore installs through a web wizard (`Atro\Controllers\Installer`); this drives the same
# endpoints non-interactively, with the credentials the platform already uses so the Node-RED
# flows authenticate as the same super admin.
#
# DESTRUCTIVE — READ THIS
# -----------------------
# The wizard's `createAdmin` calls `Installer::prepareDataBase()`, which **drops every table** in
# the target database and rebuilds it from the application's metadata. That is what a fresh
# install needs, and it is why this script:
#   * refuses to run when the application already reports itself installed (no --force), and
#   * requires an explicit `--yes`.
# Run it on a fresh instance, before installing the metadata and seeding.
#
# Usage: scripts/install-atrocore.sh --yes
#
#   ATROCORE_USERNAME / ATROCORE_PASSWORD  taken from ../compliance_flow/.env (the credentials
#                                          the Node-RED flows use) unless already in the environment
#   ATROCORE_LANGUAGE                      application language, default es_DO.
#
# The language is not cosmetic: AtroCore creates the per-language columns
# (`name_es_do`, …) during the install-time rebuild, so it has to match the languages the data
# uses. The previous instance had `es_DO`, which is why its Spanish labels exist.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
FLOW_ENV="${ROOT_DIR}/../compliance_flow/.env"
CONFIRMED=0

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED=1 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

if [[ "${CONFIRMED}" != "1" ]]; then
  cat <<'USAGE'
This installs AtroCore into the running database.

WARNING: the installer DROPS every table in the target database and rebuilds it from the
application's metadata. Only run this on a fresh instance.

Run again with --yes to continue.
USAGE
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found — copy .env.example and fill it in first (runbook §4.1)." >&2
  exit 1
fi

cd "${ROOT_DIR}"

# The caller's ATROCORE_BASE_URL has to win over the one in compliance_flow/.env, which is the
# *in-network* address (`http://atro-web/api/v1`) — right for Node-RED, wrong for this script,
# which installs over the published port from wherever it runs (a developer's host, or the dind
# service alias on a CI runner). Without this the wizard is sent to `http://atro-web/api/v1` and
# fails with "did not answer; is the stack up?" on a stack that is perfectly up. It only looked
# fine before because the existing CI job does not check out the flow repository, so nothing
# overwrote its job variable.
CALLER_ATROCORE_BASE_URL="${ATROCORE_BASE_URL:-}"

DOMAIN="localhost"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a
DOMAIN="${PRODUCTION_DOMAIN:-localhost}"

# The platform authenticates to AtroCore with these, so the super admin must be them.
if [[ -f "${FLOW_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${FLOW_ENV}"
  set +a
fi

if [[ -z "${ATROCORE_USERNAME:-}" || -z "${ATROCORE_PASSWORD:-}" ]]; then
  echo "Error: set ATROCORE_USERNAME and ATROCORE_PASSWORD (compliance_flow/.env holds the dev values)." >&2
  exit 1
fi

LANGUAGE="${ATROCORE_LANGUAGE:-es_DO}"
BASE_URL="${CALLER_ATROCORE_BASE_URL:-${ATROCORE_BASE_URL:-http://localhost}}"
SYSCONFIG="${ROOT_DIR}/web-data/${DOMAIN}/data/config.php"

if [[ -f "${SYSCONFIG}" ]] && grep -q "'isInstalled' => true" "${SYSCONFIG}"; then
  echo "install-atrocore: already installed — nothing to do."
  exit 0
fi

# The application files must exist first (bootstrap-web-data.sh is idempotent).
"${ROOT_DIR}/scripts/bootstrap-web-data.sh"

echo "install-atrocore: waiting for the application to answer …"
ready=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${BASE_URL}/" 2>/dev/null || true)"
  if [[ "${code}" == "200" || "${code}" == "302" ]]; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" != "1" ]]; then
  echo "Error: ${BASE_URL}/ did not answer; is the stack up (runbook §5.1)?" >&2
  exit 1
fi

echo "install-atrocore: setting the application language to ${LANGUAGE} …"
# The installer API path is /api/v1/Installer/<action> — deliberately NOT the usual
# /api/v1/<Controller>/action/<action>. Application::runInstallerApi() strips the prefix and
# hands the remainder straight to controllerManager->process(), and it swallows every Throwable
# into a bodiless HTTP 500, so a wrong path looks identical to a real failure.
curl -fsS -m 60 -X POST "${BASE_URL}/api/v1/Installer/setLanguage" \
  -H 'Content-Type: application/json' \
  -d "{\"language\":\"${LANGUAGE}\"}" >/dev/null

echo "install-atrocore: creating the super admin '${ATROCORE_USERNAME}' (this rebuilds the database) …"
RESPONSE="$(curl -sS -m 600 -X POST "${BASE_URL}/api/v1/Installer/createAdmin" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ATROCORE_USERNAME}\",\"password\":\"${ATROCORE_PASSWORD}\",\"confirmPassword\":\"${ATROCORE_PASSWORD}\"}")"
if ! printf '%s' "${RESPONSE}" | grep -q '"status":true'; then
  echo "Error: createAdmin failed: ${RESPONSE}" >&2
  exit 1
fi

# `/api/v1/App/user` answers 401 once the application is installed and wants authentication.
echo "install-atrocore: verifying …"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${BASE_URL}/api/v1/App/user" 2>/dev/null || true)"
  if [[ "${code}" == "401" ]]; then
    echo "install-atrocore: ok — AtroCore is installed and answering (HTTP 401 on /api/v1/App/user)."
    echo "Next: ./scripts/install-metadata.sh, then clear cache + sql diff --run."
    exit 0
  fi
  sleep 2
done

echo "Error: the application did not report itself installed (last HTTP ${code:-none})." >&2
echo "Check: docker compose logs atro-web" >&2
exit 1
