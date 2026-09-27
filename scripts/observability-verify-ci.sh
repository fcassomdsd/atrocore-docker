#!/usr/bin/env bash
#
# observability-verify-ci.sh — bring up the platform, bring up monitoring, and
# prove monitoring notices a failure.
#
# The shape is deliberately the same as restore-verify-ci.sh: build a real
# system, break it on purpose, and assert on what happened. For backups the
# thing being proved is that data comes back; here it is that a failure is
# noticed. Both are claims that a stack which merely starts cannot support.
#
#   ./scripts/observability-verify-ci.sh [--assume-populated] [--teardown]
#
#   --assume-populated  skip the platform build; it is already up.
#   --teardown          stop and remove the observability stack, then exit.
#
# Not a merge gate. It boots six projects and waits out a two-minute alert
# window, so like demo:verify and restore:verify it is manual or scheduled.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_DIR="${REPO_DIR}/observability"
WORKSPACE="${DEMO_WORKSPACE:-$(cd "${REPO_DIR}/.." && pwd)}"
ASSUME_POPULATED=0
TEARDOWN_ONLY=0

for arg in "$@"; do
  case "${arg}" in
    --assume-populated) ASSUME_POPULATED=1 ;;
    --teardown) TEARDOWN_ONLY=1 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

step() { printf '\n=== %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
die()  { printf '    FAIL %s\n' "$1" >&2; exit 1; }

obs() { docker compose -f "${OBS_DIR}/docker-compose.yaml" --env-file "${OBS_DIR}/.env" "$@"; }

if [ "${TEARDOWN_ONLY}" -eq 1 ]; then
  step "Teardown — observability stack"
  obs down -v --remove-orphans || true
  ok "removed"
  exit 0
fi

env_var() { [ -f "$1" ] && sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n1 | tr -d '"'"'"' \t'; }

# ---------------------------------------------------------------------------
if [ "${ASSUME_POPULATED}" -eq 0 ]; then
  step "1. Platform — bring the whole stack up"
  # The observability compose attaches to six networks that the six
  # application projects create. There is no way to verify monitoring against
  # a platform that is not running, so this step is not optional.
  "${SCRIPT_DIR}/demo-verify-ci.sh" || die "could not bring the platform up to monitor"
  ok "platform up"
else
  step "1. Platform — skipped (--assume-populated)"
fi

# ---------------------------------------------------------------------------
step "2. Configure — write observability/.env from the projects' own .env files"
# ---------------------------------------------------------------------------
# Read rather than invent, so the exporters use the same credentials the
# databases were actually started with. A hardcoded password here would make
# this job fail for a reason that has nothing to do with observability.
ATRO_PW="$(env_var "${REPO_DIR}/.env" POSTGRES_PASSWORD)"
ATRO_DB="$(env_var "${REPO_DIR}/.env" POSTGRES_PIM_DB)"
ALF_PW="$(env_var "${WORKSPACE}/compliance_cmis/.env" DB_PASSWORD)"
WEB_USER="$(env_var "${WORKSPACE}/compliance_web/.env" POSTGRES_USER)"
WEB_PW="$(env_var "${WORKSPACE}/compliance_web/.env" POSTGRES_PASSWORD)"
WEB_DB="$(env_var "${WORKSPACE}/compliance_web/.env" POSTGRES_DB)"

[ -n "${ATRO_PW}" ] || die "POSTGRES_PASSWORD not found in ${REPO_DIR}/.env"
[ -n "${ALF_PW}" ]  || die "DB_PASSWORD not found in compliance_cmis/.env"
[ -n "${WEB_PW}" ]  || die "POSTGRES_PASSWORD not found in compliance_web/.env"

# Under docker-in-docker the daemon publishing these ports is a different host
# from the one running this script -- it is the `docker` service alias, not
# localhost. demo-verify-ci.sh has exactly this logic for DEMO_HOST; this
# script had only the `${DEMO_HOST:-localhost}` half of it, which reads an
# environment variable that the other script sets in its OWN process and never
# exports. So in CI this resolved to localhost, and the drill failed with
# "Prometheus is not answering" on a stack where all eleven containers were up
# and every application service had just passed the full demo.
#
# GitHub's runner is the other case and must stay localhost: it runs Docker
# natively on the same host, so published ports really are on loopback. Its
# workflow sets OBS_HOST explicitly for that reason, which is why this only
# defaults to `docker` when neither variable is set.
if [ -n "${CI:-}" ] && [ -z "${OBS_HOST:-}" ] && [ -z "${DEMO_HOST:-}" ]; then
  OBS_HOST=docker
else
  OBS_HOST="${OBS_HOST:-${DEMO_HOST:-localhost}}"
fi
echo "    .. reaching the monitoring stack at ${OBS_HOST}"

cat > "${OBS_DIR}/.env" <<ENVEOF
OBS_BIND_IP=0.0.0.0
GRAFANA_ADMIN_PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
ATROCORE_PG_USER=postgres
ATROCORE_PG_PASSWORD=${ATRO_PW}
ATROCORE_PG_DB=${ATRO_DB:-postgres}
ALFRESCO_PG_USER=alfresco
ALFRESCO_PG_PASSWORD=${ALF_PW}
ALFRESCO_PG_DB=alfresco
WEB_PG_USER=${WEB_USER:-compliance}
WEB_PG_PASSWORD=${WEB_PW}
WEB_PG_DB=${WEB_DB:-compliance}
ENVEOF
# OBS_BIND_IP is 0.0.0.0 here and 127.0.0.1 everywhere else on purpose: under
# dind this script reaches Prometheus over the network, exactly as
# demo-verify-ci.sh does. It is a CI-only relaxation of a deliberate default.
ok "observability/.env written from the projects' own credentials"

# ---------------------------------------------------------------------------
step "3. Start the observability stack"
# ---------------------------------------------------------------------------
obs up -d || die "the observability stack did not start"

# Every network it attaches to is external and created by an application
# project, so a failure here is usually "the platform is not up" rather than
# anything about monitoring. Say so, instead of leaving a bare compose error.
NOT_RUNNING="$(obs ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk '$2 != "running" {print $1}')"
[ -z "${NOT_RUNNING}" ] || die "these observability containers are not running: ${NOT_RUNNING}"
ok "all observability containers running"

# ---------------------------------------------------------------------------
step "4. The drill"
# ---------------------------------------------------------------------------
PROM_URL="http://${OBS_HOST}:9090" \
ALERTMANAGER_URL="http://${OBS_HOST}:9093" \
  bash "${SCRIPT_DIR}/verify-observability.sh" \
  || die "the monitoring stack did not detect a stopped container"

printf '\n=== PASS — monitoring is up, scraping the platform, and proven to alert.\n'
