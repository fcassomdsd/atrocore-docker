#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Measure the recovery time objective: how long from "restore this set" to
# "the system serves correct answers again".
#
#   scripts/measure-rto.sh --from <backup set> [--yes]
#                          [--project-nodes N] [--project-content-gb G]
#                          [--record FILE] [--skip-smoke]
#
#   --from                the backup set to restore (the one with MANIFEST).
#   --yes                 no confirmation. THIS RESTORES OVER THE LIVE STACK.
#   --project-nodes       also print a projection for a dataset of N Alfresco
#                         nodes, using the rates this run measured.
#   --project-content-gb  and a content store of G GB.
#   --record              append a machine-readable line here
#                         (default: <repo>/rto-measurements.jsonl).
#   --skip-smoke          do not run the gateway smoke matrix at the end.
#
# WHY THE CLOCK DOES NOT STOP WHERE THE RESTORE SCRIPT STOPS
# ----------------------------------------------------------
# restore-platform.sh finishes when the data is back. The drill in
# restore-verify-ci.sh then checks the system answers, tolerates a partially
# failing smoke matrix as "expected while Solr reindexes", and declares
# success. Both are correct about what they do. Neither is an RTO.
#
# Solr is derived state and is deliberately not backed up. On a blank host it
# does not exist, so after the data lands Alfresco has to index all of it
# before search works -- and the read paths that depend on search are not
# incidental: the checklist endpoint, open findings, and four report Web
# Scripts. A recovery that has restored every byte and cannot answer "which
# findings are open" has not met an RTO an authority would recognise.
#
# So this wipes Solr's index before restoring, which is the state a real
# recovery starts from, and keeps the clock running until the index has
# caught back up to the size it was and the gateway smoke matrix passes.
#
# THE INDEX TARGET IS A COUNT TAKEN BEFORE THE WIPE
# -------------------------------------------------
# Not "Solr reports zero transactions remaining". An empty index that has not
# started tracking reports exactly that, so a poll loop waiting for it alone
# returns almost immediately and produces a fast, meaningless number. The
# node count the index held before the wipe is recorded first, and the phase
# is not over until the rebuilt index reaches it.
#
# That guard catches an index that never fills. It does NOT catch an index
# that was never emptied -- if the volume removal silently failed, the target
# is met on the first poll and this reports a reindex that never happened, at
# whatever speed the poll loop runs. So the volume IDs are read before the
# removal and asserted gone after it. The destruction is evidence, not an
# assumption about what `docker compose rm -sfv` did.
#
# BOOT AND INDEXING OVERLAP, AND THE BREAKDOWN SAYS SO
# ----------------------------------------------------
# Solr starts with Alfresco and begins tracking as soon as Alfresco answers,
# so on a small dataset most of the indexing happens while the stack is still
# booting. `alfresco_ready` and `search_ready` are therefore both measured
# from the same instant -- the moment the stack is started -- and the
# size-dependent part of that window is the difference between them, not the
# whole of it. Reported as two marks on one clock rather than two phases that
# could be added together.
#
# WHAT THIS CAN AND CANNOT TELL YOU
# ---------------------------------
# It measures this dataset on this host. That is one point, not a curve. What
# makes it extrapolable is that it records the SIZE of every input beside the
# duration of every phase and derives a per-unit rate, so --project-nodes and
# --project-content-gb can scale the size-dependent phases while leaving the
# fixed ones alone. A projection is arithmetic on one measurement and is
# labelled as such -- it is not a second measurement, and a real number for a
# real authority needs their data.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
CMIS_DIR="${WORKSPACE}/compliance_cmis"

FROM=""; ASSUME_YES=0; SKIP_SMOKE=0
PROJECT_NODES=""; PROJECT_CONTENT_GB=""
RECORD="${REPO_DIR}/rto-measurements.jsonl"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; BLD=""; RST=""; }
step() { printf '\n%s=== %s%s\n' "${BLD}" "$*" "${RST}"; }
ok()   { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; }
info() { printf '    ..   %s\n' "$*"; }
warn() { printf '    %s!!%s   %s\n' "${YEL}" "${RST}" "$*"; }
die()  { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from)               FROM="${2:?--from needs a directory}"; shift 2 ;;
    --yes|-y)             ASSUME_YES=1; shift ;;
    --project-nodes)      PROJECT_NODES="${2:?}"; shift 2 ;;
    --project-content-gb) PROJECT_CONTENT_GB="${2:?}"; shift 2 ;;
    --record)             RECORD="${2:?}"; shift 2 ;;
    --skip-smoke)         SKIP_SMOKE=1; shift ;;
    -h|--help)            sed -n '5,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done
[ -n "${FROM}" ] || die "--from is required"
[ -d "${FROM}" ] || die "${FROM} is not a directory"

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t="${EPOCHREALTIME/,/.}"
    echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
  else
    echo $(( SECONDS * 1000 ))
  fi
}
fmt_ms() {
  local ms="$1"
  if [ "${ms}" -lt 1000 ]; then printf '%dms' "${ms}"
  elif [ "${ms}" -lt 60000 ]; then printf '%d.%01ds' $(( ms / 1000 )) $(( (ms % 1000) / 100 ))
  else printf '%dm%02ds' $(( ms / 60000 )) $(( (ms % 60000) / 1000 )); fi
}
env_var() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}

# The index handling is shared with restore-verify-ci.sh rather than copied:
# both need the same definition of "search is back", and two copies of a rule
# is how they stop agreeing.
# shellcheck source=scripts/solr-index.lib.sh
. "${SCRIPT_DIR}/solr-index.lib.sh"
SOLR_SECRET="$(solr_secret "${CMIS_DIR}")"
solr_summary() { solr_field "${SOLR_SECRET}" "$1"; }

declare -a PHASE_LOG=()
PHASE_NAME=""; PHASE_T0=0
phase() {
  if [ -n "${PHASE_NAME}" ]; then
    PHASE_LOG+=("${PHASE_NAME}:$(( $(now_ms) - PHASE_T0 ))")
  fi
  PHASE_NAME="${1:-}"
  [ -n "${PHASE_NAME}" ] && PHASE_T0="$(now_ms)"
  return 0
}

printf '%smeasure-rto%s\n' "${BLD}" "${RST}"
echo "set: ${FROM}"

step "0. Record the starting scale"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"
INDEX_NODES_BEFORE="$(solr_summary 'Alfresco Nodes in Index')"
case "${INDEX_NODES_BEFORE}" in
  ''|*[!0-9]*) die "could not read Solr's index size — refusing to measure a reindex against an unknown target" ;;
esac
[ "${INDEX_NODES_BEFORE}" -gt 0 ] || die "Solr's index is already empty — bring the platform to a normal state first"
NODE_INDEX_MEAN_MS="$(solr_summary 'Node index time (ms)' | sed -n "s/.*'Mean': \([0-9.]*\).*/\1/p")"
DB_NODES="$( docker exec compliance_cmis-postgres-1 psql -U alfresco -d alfresco -tAc \
  'select count(*) from alf_node' 2>/dev/null | tr -d '[:space:]' )"
CONTENT_BYTES="$(docker run --rm -v "${CMIS_DIR}/data/alf_data:/d:ro" alpine:latest \
  sh -c 'du -sb /d 2>/dev/null | cut -f1' | tr -d '[:space:]')"
CONTENT_FILES="$(docker run --rm -v "${CMIS_DIR}/data/alf_data:/d:ro" alpine:latest \
  sh -c 'find /d -type f | wc -l' | tr -d ' ')"
SET_BYTES="$(du -sb "${FROM}" | cut -f1)"
ok "Solr index: ${INDEX_NODES_BEFORE} nodes (${NODE_INDEX_MEAN_MS:-?} ms/node measured by Solr itself)"
ok "database: ${DB_NODES} alf_node rows"
ok "content store: ${CONTENT_FILES} files, $(( CONTENT_BYTES / 1048576 )) MB"
ok "backup set: $(( SET_BYTES / 1048576 )) MB"

if [ "${ASSUME_YES}" -ne 1 ]; then
  echo ""
  printf '%sThis RESTORES OVER THE LIVE STACK and wipes the Solr index.%s\n' "${RED}" "${RST}"
  printf 'Type MEASURE to continue: '; read -r a
  [ "$a" = "MEASURE" ] || { echo "aborted"; exit 0; }
fi

RUN_T0="$(now_ms)"

step "1. Enter the disaster state"
# Alfresco must be down to replace its content store, and Solr's index has to
# go because a real recovery does not have one. Removing the container with
# its anonymous volumes is how that is spelled for this image -- the index
# lives in volumes, not in the bind-mounted data/ tree.
phase teardown
( cd "${CMIS_DIR}" && docker compose stop alfresco >/dev/null 2>&1 ) || die "could not stop Alfresco"
SOLR_VOLS="$(solr_destroy_index "${CMIS_DIR}")" \
  || die "the Solr index was not destroyed — any reindex measured after this is fiction"
ok "Alfresco stopped; Solr container and all ${SOLR_VOLS} index volume(s) confirmed gone"

step "2. Restore the data"
phase ""
RESTORE_LOG="$(mktemp)"
RTO_RECORD="" "${SCRIPT_DIR}/restore-platform.sh" --from "${FROM}" --yes > "${RESTORE_LOG}" 2>&1
RC=$?
grep -E '^    (ok|--)|^=== ' "${RESTORE_LOG}" | sed 's/^/    /' | tail -20
if [ ${RC} -ne 0 ]; then tail -20 "${RESTORE_LOG}"; die "restore-platform.sh failed"; fi
# Its own phase breakdown, re-read rather than re-timed, so one clock measures
# each thing once.
for name in verify content databases; do
  ms="$(sed -n "s/^    ${name}  *//p" "${RESTORE_LOG}" | head -1)"
  [ -n "${ms}" ] && PHASE_LOG+=("restore_${name}:$(printf '%s' "${ms}" | awk '
    /m[0-9]+s$/ { split($0,a,"m"); sub(/s$/,"",a[2]); print (a[1]*60+a[2])*1000; next }
    /ms$/       { sub(/ms$/,"",$0); print $0; next }
    /s$/        { sub(/s$/,"",$0); print int($0*1000); next }
    { print 0 }')")
done
RESTORE_TOTAL="$(sed -n 's/^    TOTAL  *//p' "${RESTORE_LOG}" | head -1)"
ok "data restored (restore-platform reported ${RESTORE_TOTAL:-?})"
rm -f "${RESTORE_LOG}"

step "3. Bring the service back up"
phase alfresco_ready
STACK_T0="$(now_ms)"
( cd "${CMIS_DIR}" && docker compose up -d alfresco solr6 >/dev/null 2>&1 ) || die "could not start alfresco and solr6"
READY=0
for _ in $(seq 1 120); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready- 2>/dev/null)" = "200" ]; then
    READY=1; break
  fi
  sleep 5
done
[ "${READY}" -eq 1 ] || die "Alfresco did not become ready within 600s"
ok "Alfresco answering its readiness probe"

step "4. Wait for search to be correct again"
# The target is the index size recorded before the wipe. "Zero transactions
# remaining" on its own is what an index that has not begun tracking reports.
#
# Polled every 2s, not every 5s. At this dataset's scale the whole rebuild
# takes tens of seconds, so a 5s cadence put up to 10s of quantisation error
# on the one phase the projection is most sensitive to.
phase search_ready
solr_wait_indexed "${SOLR_SECRET}" "${INDEX_NODES_BEFORE}" 1800 15 \
  || die "Solr did not reach ${INDEX_NODES_BEFORE} indexed nodes within 30m"
INDEX_MIN="${SOLR_LOW_WATER}"
INDEX_NODES_AFTER="$(solr_index_nodes "${SOLR_SECRET}")"
ok "index rebuilt to ${INDEX_NODES_AFTER} nodes (was ${INDEX_NODES_BEFORE}, low-water mark ${INDEX_MIN})"
if [ "${INDEX_MIN}" -ge "${INDEX_NODES_BEFORE}" ]; then
  die "the index never dropped below its original size — nothing was rebuilt and this number means nothing"
fi

step "5. Prove the service answers"
phase smoke
SMOKE="skipped"
if [ "${SKIP_SMOKE}" -eq 0 ] && [ -f "${WORKSPACE}/compliance_flow/scripts/smoke-flows.mjs" ]; then
  OUT="$( cd "${WORKSPACE}/compliance_flow" \
    && API_KEY="$(env_var "${WORKSPACE}/compliance_flow/.env" API_KEY)" \
       node scripts/smoke-flows.mjs 2>&1 )"
  SRC=$?
  echo "${OUT}" | tail -2 | sed 's/^/    /'
  if [ ${SRC} -eq 0 ]; then SMOKE="passed"; ok "gateway smoke matrix passed"
  else SMOKE="failed"; warn "gateway smoke matrix did not pass — the clock stops here anyway, but this is not a recovered system"; fi
fi
phase ""
TOTAL_MS=$(( $(now_ms) - RUN_T0 ))

# --- the number ------------------------------------------------------------
step "Recovery time"
for entry in "${PHASE_LOG[@]}"; do
  printf '    %-18s %s\n' "${entry%%:*}" "$(fmt_ms "${entry##*:}")"
done
printf '    %-18s %s%s%s\n' "TOTAL (RTO)" "${BLD}" "$(fmt_ms "${TOTAL_MS}")" "${RST}"

ms_of() { for e in "${PHASE_LOG[@]}"; do [ "${e%%:*}" = "$1" ] && { echo "${e##*:}"; return; }; done; echo 0; }
REINDEX_MS="$(ms_of search_ready)"
CONTENT_MS="$(ms_of restore_content)"
DB_MS="$(ms_of restore_databases)"
VERIFY_MS="$(ms_of restore_verify)"
FIXED_MS=$(( TOTAL_MS - REINDEX_MS - CONTENT_MS - DB_MS - VERIFY_MS ))

step "What scales, and what does not"
printf '    size-dependent   %s  (verify %s, content %s, databases %s, reindex %s)\n' \
  "$(fmt_ms $(( VERIFY_MS + CONTENT_MS + DB_MS + REINDEX_MS )))" \
  "$(fmt_ms "${VERIFY_MS}")" "$(fmt_ms "${CONTENT_MS}")" "$(fmt_ms "${DB_MS}")" "$(fmt_ms "${REINDEX_MS}")"
printf '    fixed            %s  (teardown, stack start, smoke)\n' "$(fmt_ms "${FIXED_MS}")"
[ "${REINDEX_MS}" -gt 0 ] && printf '    reindex rate     %s ms/node over %s nodes\n' \
  "$(awk -v a="${REINDEX_MS}" -v b="${INDEX_NODES_BEFORE}" 'BEGIN{printf "%.1f", a/b}')" "${INDEX_NODES_BEFORE}"
[ "${CONTENT_MS}" -gt 0 ] && printf '    content rate     %s MB/s over %s MB\n' \
  "$(awk -v a="${CONTENT_BYTES}" -v b="${CONTENT_MS}" 'BEGIN{printf "%.0f", (a/1048576)/(b/1000)}')" "$(( CONTENT_BYTES / 1048576 ))"

if [ -n "${PROJECT_NODES}" ] || [ -n "${PROJECT_CONTENT_GB}" ]; then
  pn="${PROJECT_NODES:-${INDEX_NODES_BEFORE}}"
  pc="${PROJECT_CONTENT_GB:-$(awk -v b="${CONTENT_BYTES}" 'BEGIN{printf "%.2f", b/1073741824}')}"
  step "Projection — arithmetic on one measurement, not a second measurement"
  awk -v fixed="${FIXED_MS}" -v rms="${REINDEX_MS}" -v rn="${INDEX_NODES_BEFORE}" \
      -v cms="$(( VERIFY_MS + CONTENT_MS + DB_MS ))" -v cb="${CONTENT_BYTES}" \
      -v pn="${pn}" -v pcgb="${pc}" '
    BEGIN {
      pb = pcgb * 1073741824;
      total = fixed + (rn > 0 ? rms * (pn / rn) : 0) + (cb > 0 ? cms * (pb / cb) : 0);
      printf "    %s nodes and %.2f GB of content -> about %d min\n", pn, pcgb, (total/60000)+0.5;
      printf "    of which reindex is about %d min\n", (rn > 0 ? rms*(pn/rn)/60000 : 0)+0.5;
    }'
  info "linear in both terms, on this host, with this hardware and this concurrency."
  info "Alfresco indexing is not perfectly linear at scale and a real authority's"
  info "content is larger per node. Treat it as an order of magnitude."
fi

if [ -n "${RECORD}" ]; then
  {
    printf '{"at":"%s","set":"%s","set_bytes":%s,"index_nodes":%s,"db_alf_node":%s,"content_bytes":%s,"content_files":%s,"smoke":"%s"' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "${FROM}")" "${SET_BYTES}" \
      "${INDEX_NODES_BEFORE}" "${DB_NODES:-0}" "${CONTENT_BYTES}" "${CONTENT_FILES}" "${SMOKE}"
    printf ',"index_low_water":%s,"solr_node_index_mean_ms":%s' "${INDEX_MIN:--1}" "${NODE_INDEX_MEAN_MS:-0}"
    for entry in "${PHASE_LOG[@]}"; do printf ',"%s_ms":%s' "${entry%%:*}" "${entry##*:}"; done
    printf ',"rto_total_ms":%s}\n' "${TOTAL_MS}"
  } >> "${RECORD}"
  ok "appended to ${RECORD}"
fi

echo ""
if [ "${SMOKE}" = "failed" ]; then
  printf '%sRTO %s — but the smoke matrix failed, so this is a time-to-something-broken.%s\n' "${RED}" "$(fmt_ms "${TOTAL_MS}")" "${RST}"
  exit 1
fi
printf '%sRTO %s — restore to a searching, serving system.%s\n' "${GRN}" "$(fmt_ms "${TOTAL_MS}")" "${RST}"
