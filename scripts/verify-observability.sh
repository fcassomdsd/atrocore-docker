#!/usr/bin/env bash
#
# verify-observability.sh — prove the monitoring stack actually detects a
# failure, rather than that it merely started.
#
# WHY THIS EXISTS
# ---------------
# A Prometheus that is running, a Grafana with a dashboard and a set of alert
# rules that parse are all easy to mistake for monitoring. None of them shows
# that anything would be noticed. Every failure this stack was built for --
# a wedged ActiveMQ, a silently failing WAL archiver -- is one where the
# system looks fine, so "it looks fine" is exactly the evidence that cannot be
# trusted here.
#
# So this script breaks something on purpose and waits for the alert. It stops
# a container, waits for the rule to move through pending into firing, checks
# that Alertmanager received it, restarts the container, and waits for the
# alert to clear. If any of that does not happen, the monitoring is not
# monitoring and the script fails.
#
# It is destructive in a bounded way: it stops exactly one container and
# starts it again. The default target is compliance_import, chosen because it
# is stateless, starts in seconds, and nothing else depends on it being up --
# stopping Alfresco to test an alert would cost ten minutes to undo.
#
# Usage:
#   scripts/verify-observability.sh [--target <container>] [--keep-broken]
#
#   --target        container to stop (default: compliance-import)
#   --keep-broken   leave the container stopped at the end, for inspecting
#                   the alert by hand. Off by default: a verification script
#                   that leaves the system broken is a trap.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS_DIR="${ROOT_DIR}/observability"
PROM="${PROM_URL:-http://127.0.0.1:9090}"
ALERTMANAGER="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
# compliance-backend is the default because it has a fixed container_name, it
# restarts in seconds, and nothing else depends on it being up. Stopping
# Alfresco to test an alert would cost ten minutes to undo.
TARGET="compliance-backend"
KEEP_BROKEN=0

# The alert has `for: 2m`, and Prometheus evaluates every 30s and scrapes every
# 30s. Worst case is roughly scrape + for + evaluation, so ~3m30s; 6 minutes
# leaves real headroom on a loaded host without the script hanging forever if
# something is genuinely wrong.
FIRE_TIMEOUT="${FIRE_TIMEOUT:-360}"
CLEAR_TIMEOUT="${CLEAR_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a container name}"; shift 2 ;;
    --keep-broken) KEEP_BROKEN=1; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n=== %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
info() { printf '    ..   %s\n' "$1"; }
die()  { printf '    FAIL %s\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }
need curl
need docker
need python3

# jq is not assumed -- it is not installed on every host this has to run on,
# and CI images vary. python3 is already a dependency of other scripts here.
jget() { python3 -c "$1"; }

# Only true once the container has actually been stopped. Without it the trap
# printed "restoring <container>" on every early exit -- including a preflight
# failure, where nothing had been touched -- which reads as though the drill
# broke something before giving up.
STOPPED=0
RESTORED=0
restore() {
  if [[ "${STOPPED}" -eq 1 && "${RESTORED}" -eq 0 && "${KEEP_BROKEN}" -eq 0 ]]; then
    RESTORED=1
    printf '\n    restoring %s\n' "${TARGET}"
    docker start "${TARGET}" >/dev/null 2>&1 || true
  fi
}
# Restore on any exit, including an interrupt or a failed assertion. A drill
# that leaves a service down when it fails halfway is worse than no drill.
trap restore EXIT INT TERM

# ---------------------------------------------------------------------------
step "1. Preflight — the monitoring stack itself"
# ---------------------------------------------------------------------------
[[ -f "${OBS_DIR}/docker-compose.yaml" ]] || die "observability/docker-compose.yaml not found"

curl -fsS -m 10 "${PROM}/-/healthy" >/dev/null 2>&1 \
  || die "Prometheus is not answering at ${PROM} — start it first:
         docker compose -f observability/docker-compose.yaml up -d"
ok "Prometheus healthy"

curl -fsS -m 10 "${ALERTMANAGER}/-/healthy" >/dev/null 2>&1 \
  || die "Alertmanager is not answering at ${ALERTMANAGER}"
ok "Alertmanager healthy"

# Rules that fail to load leave Prometheus running and alerting on nothing --
# the single most plausible way this whole stack becomes decorative.
RULE_ERRORS=$(curl -fsS -m 10 "${PROM}/api/v1/rules" \
  | jget "import json,sys
d=json.load(sys.stdin)
bad=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('health') not in (None,'ok','unknown')]
print(','.join(bad))")
[[ -z "${RULE_ERRORS}" ]] || die "alert rules are not healthy: ${RULE_ERRORS}"

RULE_COUNT=$(curl -fsS -m 10 "${PROM}/api/v1/rules" \
  | jget "import json,sys
d=json.load(sys.stdin)
print(sum(len(g['rules']) for g in d['data']['groups']))")
[[ "${RULE_COUNT}" -gt 0 ]] || die "Prometheus loaded zero alert rules — check observability/prometheus/rules/"
ok "${RULE_COUNT} alert rules loaded and healthy"

# ---------------------------------------------------------------------------
step "2. Preflight — targets are actually being scraped"
# ---------------------------------------------------------------------------
# A target that has never been scraped cannot alert, and Prometheus reports
# that as a quiet "unknown" rather than an error.
read -r UP_COUNT DOWN_LIST < <(curl -fsS -m 10 "${PROM}/api/v1/targets?state=active" \
  | jget "import json,sys
d=json.load(sys.stdin)['data']['activeTargets']
up=[t for t in d if t['health']=='up']
down=[t['labels'].get('instance', t['scrapeUrl']) for t in d if t['health']!='up']
print(len(up), ','.join(down) if down else '-')")

ok "${UP_COUNT} scrape targets up"
if [[ "${DOWN_LIST}" != "-" ]]; then
  # Not fatal. This drill is routinely run against a partially started
  # platform, and a down target for a service that is deliberately not running
  # is the correct reading, not a fault in the monitoring.
  info "targets not up (expected if that part of the platform is stopped): ${DOWN_LIST}"
fi

docker inspect "${TARGET}" >/dev/null 2>&1 \
  || die "container '${TARGET}' does not exist — pass --target <name>, or start the platform first"

RUNNING=$(docker inspect -f '{{.State.Running}}' "${TARGET}")
[[ "${RUNNING}" == "true" ]] || die "container '${TARGET}' is not running; the drill needs something healthy to break"
ok "target container '${TARGET}' is running"

# The probe for the target must be passing BEFORE we break it. Without this
# the drill can "pass" by observing an alert that was already firing.
probe_value() {
  curl -fsS -m 10 --get "${PROM}/api/v1/query" \
    --data-urlencode 'query=probe_success{probe_kind="health"}' \
    | jget "import json,sys
d=json.load(sys.stdin)['data']['result']
hit=[r for r in d if '${TARGET_HOST}' in r['metric'].get('instance','')]
print(hit[0]['value'][1] if hit else 'none')"
}

# Map the container to the hostname its probe uses.
# Container names and probe hostnames are not the same thing, and only one of
# the services involved fixes its container_name -- the rest get Compose's
# generated `<project>-<service>-<n>`, so these patterns match loosely.
case "${TARGET}" in
  compliance-backend)   TARGET_HOST="backend:4000" ;;
  *compliance-import*)  TARGET_HOST="compliance-import:8000" ;;
  *node-red*)           TARGET_HOST="node-red:1880" ;;
  *atro-web*)           TARGET_HOST="atro-web:80" ;;
  *) TARGET_HOST="" ;;
esac
[[ -n "${TARGET_HOST}" ]] \
  || die "no health probe is configured for '${TARGET}' — this drill can only verify a container that Prometheus probes"

BEFORE=$(probe_value)
[[ "${BEFORE}" == "1" ]] \
  || die "probe for ${TARGET_HOST} reads '${BEFORE}', not 1 — it must be passing before the drill breaks it,
         otherwise a 'firing' alert afterwards proves nothing. Wait for the first scrape, or fix the service."
ok "probe for ${TARGET_HOST} is passing (baseline established)"

# ---------------------------------------------------------------------------
step "3. Break it — stop ${TARGET}"
# ---------------------------------------------------------------------------
docker stop "${TARGET}" >/dev/null
STOPPED=1
ok "stopped ${TARGET}"

# ---------------------------------------------------------------------------
step "4. Wait for ServiceHealthProbeFailing to fire"
# ---------------------------------------------------------------------------
alert_state() {
  curl -fsS -m 10 "${PROM}/api/v1/alerts" \
    | jget "import json,sys
d=json.load(sys.stdin)['data']['alerts']
hit=[a for a in d if a['labels'].get('alertname')=='ServiceHealthProbeFailing'
     and '${TARGET_HOST}' in a['labels'].get('instance','')]
print(hit[0]['state'] if hit else 'none')"
}

deadline=$((SECONDS + FIRE_TIMEOUT))
state=none
while (( SECONDS < deadline )); do
  state=$(alert_state)
  case "${state}" in
    firing) break ;;
    pending) info "alert is pending (${SECONDS}s elapsed) — waiting out the rule's 'for' window" ;;
    *) info "no alert yet (${SECONDS}s elapsed) — waiting for the next scrape" ;;
  esac
  sleep 15
done

[[ "${state}" == "firing" ]] \
  || die "ServiceHealthProbeFailing did not reach 'firing' for ${TARGET_HOST} within ${FIRE_TIMEOUT}s (last state: ${state}).
         The monitoring did not notice a service being stopped, which is the one thing it exists to do."
ok "Prometheus alert is FIRING for ${TARGET_HOST}"

# ---------------------------------------------------------------------------
step "5. Confirm Alertmanager received it"
# ---------------------------------------------------------------------------
# Firing in Prometheus and arriving at Alertmanager are two different things.
# A broken `alerting:` block, an unreachable Alertmanager or an over-broad
# inhibit rule all produce an alert that fires and notifies nobody -- and that
# failure is invisible from the Prometheus UI, which is where people look.
am_has_alert() {
  curl -fsS -m 10 "${ALERTMANAGER}/api/v2/alerts?active=true" \
    | jget "import json,sys
d=json.load(sys.stdin)
hit=[a for a in d if a['labels'].get('alertname')=='ServiceHealthProbeFailing'
     and '${TARGET_HOST}' in a['labels'].get('instance','')]
print('yes' if hit else 'no')
" 2>/dev/null || echo no
}

deadline=$((SECONDS + 120))
got=no
while (( SECONDS < deadline )); do
  got=$(am_has_alert)
  [[ "${got}" == "yes" ]] && break
  info "not in Alertmanager yet — waiting"
  sleep 10
done
[[ "${got}" == "yes" ]] \
  || die "the alert is firing in Prometheus but never reached Alertmanager.
         Check the 'alerting:' block in observability/prometheus/prometheus.yml and that
         alertmanager is on the obs_net network."
ok "Alertmanager holds the alert (it would notify, if a receiver were configured)"

# Whether a notification was actually SENT is deliberately not asserted: the
# default configuration has no receiver, because a tracked config file is no
# place for an SMTP password. Delivery is an operator's configuration step,
# documented in observability/README.md; detection is what this drill proves.

# ---------------------------------------------------------------------------
step "6. Fix it — restart ${TARGET} and watch the alert clear"
# ---------------------------------------------------------------------------
if [[ "${KEEP_BROKEN}" -eq 1 ]]; then
  info "--keep-broken given; leaving ${TARGET} stopped. Start it with: docker start ${TARGET}"
  printf '\n=== PASS — the monitoring detected a stopped container and Alertmanager received the alert.\n'
  exit 0
fi

restore
RESTORED=1

deadline=$((SECONDS + CLEAR_TIMEOUT))
state=firing
while (( SECONDS < deadline )); do
  state=$(alert_state)
  [[ "${state}" == "none" ]] && break
  info "alert still ${state} — waiting for it to resolve"
  sleep 15
done

# An alert that fires and never clears is its own failure: it trains people to
# ignore the dashboard, and it hides the next real incident behind a stale red.
[[ "${state}" == "none" ]] \
  || die "the alert did not clear within ${CLEAR_TIMEOUT}s of ${TARGET} coming back (state: ${state}).
         An alert that never resolves is as bad as one that never fires."
ok "alert cleared after the service recovered"

printf '\n=== PASS — a stopped container fired an alert, reached Alertmanager, and resolved on recovery.\n'
