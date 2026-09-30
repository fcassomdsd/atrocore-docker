#!/usr/bin/env bash
#
# verify-pitr.sh — the point-in-time recovery drill.
#
#   ./scripts/verify-pitr.sh [--dataset atrocore] [--base FILE] [--port 55432]
#                            [--workdir DIR] [--keep]
#
#   --dataset  atrocore | alfresco | compliance_web (default: atrocore, the
#              smallest of the three).
#   --base     use an existing *.basebackup.tar from a stored set. Without it
#              the drill takes its own, which proves the mechanism but not
#              that the sets you keep are usable -- so a real drill should
#              point this at last night's set.
#   --port     host port for the recovery instance (default 55432).
#   --workdir  where to unpack the base backup and the recovery cluster
#              (default: a fresh directory under /tmp). Under
#              docker-in-docker this MUST be a path the Docker daemon shares
#              with this container, because the extraction and the recovery
#              server are containers -- see the note above the default below.
#   --keep     leave the recovered instance running.
#
# WHAT IT DOES, AND WHY IN THIS ORDER
#
#   base backup -> marker A -> T -> marker B -> WAL switch -> recover to T
#
# Then it asserts A is present and **B is absent**. B is the whole drill. A
# recovery that replays everything also contains A, so finding A proves only
# that the base backup works -- which the logical-dump restore already covers.
# Only the absence of B shows that replay stopped where it was told, which is
# the property a point-in-time recovery is for: rewinding past a bad write
# without losing the good ones before it.
#
# THE WAL SWITCH IS NOT HOUSEKEEPING
#
# PostgreSQL archives a segment when it is full or when archive_timeout
# expires -- five minutes here. Both markers sit in the current, unarchived
# segment until then, so a drill that skips the switch recovers to a point
# before either of them and cheerfully reports that neither is present, which
# looks like a pass for the wrong reason. The drill forces a switch and waits
# for the segment to appear in the archive before recovering.
#
# IT WRITES TO THE LIVE DATABASE
#
# One table, `pitr_drill_marker`, created and dropped, in the live cluster --
# because a drill against a database nobody uses proves nothing about this
# platform's WAL configuration. It touches no application table and is removed
# on every exit path, including failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"

DATASET="atrocore"
BASE=""
WORKDIR_OPT=""
PORT=55432
KEEP=0

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; BLD=""; RST=""; }
PASS=0; FAILED=0

step() { printf '\n%s==> %s%s\n' "${BLD}" "$*" "${RST}"; }
ok()   { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; PASS=$((PASS + 1)); }
info() { printf '         %s\n' "$*"; }
warn() { printf '    %swarn%s %s\n' "${YEL}" "${RST}" "$*"; }
no()   { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*"; FAILED=$((FAILED + 1)); }
die()  { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dataset) DATASET="${2:-}"; shift 2 ;;
    --base)    BASE="${2:-}"; shift 2 ;;
    --port)    PORT="${2:-}"; shift 2 ;;
    --workdir) WORKDIR_OPT="${2:-}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# An --env-file override, same convention as verify-wal-archiving.sh's
# WAL_ENV_FILE. CI has no .env -- the repos ship .env.example -- so without
# this the drill can only ever run against a developer's own checkout, which
# is how the restore path went unexercised for days.
PITR_ENV_FILE="${PITR_ENV_FILE:-}"
COMPOSE=(docker compose)
[ -n "${PITR_ENV_FILE}" ] && COMPOSE=(docker compose --env-file "${PITR_ENV_FILE}")

env_var() { # env_var <file> <name>
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}

# The superuser to drive the drill with. pg_basebackup needs a replication
# connection and pg_switch_wal() needs superuser, so the application role is
# not enough -- which is the defect this drill found on its first run.
case "${DATASET}" in
  atrocore)
    DS_DIR="${REPO_DIR}"; DS_SVC="db"; DS_SUPER="postgres"
    DS_DB="$(env_var "${PITR_ENV_FILE:-${REPO_DIR}/.env}" POSTGRES_PIM_DB)"
    DS_ARCHIVE="${REPO_DIR}/wal-archive" ;;
  alfresco)
    DS_DIR="${WORKSPACE}/compliance_cmis"; DS_SVC="postgres"; DS_SUPER="alfresco"
    DS_DB="alfresco"
    DS_ARCHIVE="${WORKSPACE}/compliance_cmis/data/wal-archive" ;;
  compliance_web)
    DS_DIR="${WORKSPACE}/compliance_web"; DS_SVC="db"
    DS_SUPER="$(env_var "${PITR_ENV_FILE:-${WORKSPACE}/compliance_web/.env}" POSTGRES_USER)"
    DS_DB="$(env_var "${PITR_ENV_FILE:-${WORKSPACE}/compliance_web/.env}" POSTGRES_DB)"
    DS_ARCHIVE="${WORKSPACE}/compliance_web/data/wal-archive" ;;
  *) die "unknown dataset: ${DATASET}" ;;
esac
[ -n "${DS_DB}" ] || die "could not resolve the database name for ${DATASET}"

psql_live() { ( cd "${DS_DIR}" && "${COMPOSE[@]}" exec -T "${DS_SVC}" psql -U "${DS_SUPER}" -d "${DS_DB}" -tAc "$1" ) 2>/dev/null | tr -d '\r'; }

# Where the drill unpacks the base backup and the recovery cluster.
#
# Default /tmp is right on a workstation and WRONG under docker-in-docker: the
# extraction and the recovery server both run as containers, so the daemon
# resolves these paths on ITS filesystem, not this one's. A /tmp path that
# exists only here makes Docker silently create an empty DIRECTORY on the
# daemon side and mount that instead -- the base backup arrives as a directory
# and tar reports "invalid tar magic", which reads like a corrupt backup.
#
# Hence --workdir: under dind, point it somewhere both sides genuinely share
# (in GitLab CI that is the build directory, which the runner mounts into the
# dind service too). restore-pitr.sh asserts the mount arrived regardless.
if [ -n "${WORKDIR_OPT}" ]; then
  mkdir -p "${WORKDIR_OPT}" || die "cannot create --workdir ${WORKDIR_OPT}"
  WORKDIR="$(cd "${WORKDIR_OPT}" && pwd)"
else
  WORKDIR="$(mktemp -d -t pitr-drill-XXXXXX)"
fi
CLEANED=0
cleanup() {
  [ "${CLEANED}" -eq 1 ] && return
  CLEANED=1
  # The drill table goes, on every exit path. A drill that leaves scaffolding
  # in a production database is worse than no drill.
  psql_live "DROP TABLE IF EXISTS pitr_drill_marker" >/dev/null 2>&1
  # restore-pitr.sh is called with --keep so the assertions can query the
  # instance, and it deliberately leaves a FAILED recovery in place for a
  # human to inspect. Neither is right for a drill that aborts early, which
  # is how three orphaned containers accumulated while mutation-testing this.
  if [ "${KEEP}" -eq 0 ]; then
    for c in $(docker ps -a --filter "name=pitr-${DATASET}-" --format '{{.Names}}' 2>/dev/null); do
      docker rm -f "${c}" >/dev/null 2>&1
    done
  fi
  if [ "${KEEP}" -eq 0 ] && [ -d "${WORKDIR}" ]; then
    docker run --rm -v "${WORKDIR}:/w" alpine:latest sh -c 'rm -rf /w/*' >/dev/null 2>&1
    # An explicit --workdir may be a directory the caller owns and reuses, so a
    # refusal to remove it is not an error -- and this runs inside an EXIT trap,
    # where a non-zero last command would replace the real exit status.
    rmdir "${WORKDIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

printf '%spitr drill — dataset: %s%s\n' "${BLD}" "${DATASET}" "${RST}"

step "1. Preconditions"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"
( cd "${DS_DIR}" && "${COMPOSE[@]}" ps --status running --format '{{.Service}}' 2>/dev/null ) | grep -qx "${DS_SVC}" \
  || die "${DATASET}: service '${DS_SVC}' is not running"
ARCH_MODE="$(psql_live 'show archive_mode')"
[ "${ARCH_MODE}" = "on" ] || die "archive_mode is '${ARCH_MODE}' — there is no archive to recover from"
ok "service running, archive_mode=on, archive_timeout=$(psql_live 'show archive_timeout')"

# A failing archiver makes everything below meaningless: the segments exist in
# pg_wal and never reach the archive, so recovery silently stops early.
# One row, three fields, read together. Written as three separate queries at
# first, two of which had no FROM clause -- psql errored, 2>/dev/null ate it,
# both variables came back empty, and the check below could never fire while
# reporting "last archived never" about a database that was archiving fine. A
# precondition that cannot fail is not a precondition.
ARCHIVER="$(psql_live "select failed_count || '|' || coalesce(last_archived_time::text,'') || '|' || coalesce(last_failed_time::text,'') from pg_stat_archiver")"
[ -n "${ARCHIVER}" ] || die "could not read pg_stat_archiver — refusing to drill against an archiver whose state is unknown"
FAILED_COUNT="${ARCHIVER%%|*}"
REST="${ARCHIVER#*|}"
LAST_ARCHIVED="${REST%%|*}"
LAST_FAILED="${REST#*|}"
if [ -z "${LAST_ARCHIVED}" ]; then
  die "this database has never archived a WAL segment (failed_count=${FAILED_COUNT}, last failure ${LAST_FAILED:-none}) — there is nothing to recover from"
fi
if [ -n "${LAST_FAILED}" ] && [ "${LAST_FAILED}" \> "${LAST_ARCHIVED}" ]; then
  die "the archiver's last attempt FAILED (${LAST_FAILED}, after the last success at ${LAST_ARCHIVED}) — segments are accumulating and recovery would stop early"
fi
ok "archiver healthy (failed_count=${FAILED_COUNT}, last archived ${LAST_ARCHIVED})"

step "2. Base backup"
if [ -n "${BASE}" ]; then
  [ -f "${BASE}" ] || die "base backup not found: ${BASE}"
  ok "using a stored base backup: ${BASE}"
  info "this drills the sets you actually keep, which is the stronger test"
else
  BASE="${WORKDIR}/${DATASET}.basebackup.tar"
  ( cd "${DS_DIR}" && "${COMPOSE[@]}" exec -T "${DS_SVC}" \
      pg_basebackup -U "${DS_SUPER}" -D - -Ft -Xf ) > "${BASE}" 2>"${WORKDIR}/bb.err"
  [ -s "${BASE}" ] || { sed 's/^/         /' "${WORKDIR}/bb.err" | head -3; die "pg_basebackup failed"; }
  ok "took a fresh base backup: $(du -h "${BASE}" | cut -f1)"
  warn "no --base given, so this proves the mechanism, not that a stored set is usable"
fi

step "3. Write marker A, take the target time, write marker B"
psql_live "DROP TABLE IF EXISTS pitr_drill_marker" >/dev/null
psql_live "CREATE TABLE pitr_drill_marker (marker text primary key, written_at timestamptz default now())" >/dev/null
psql_live "INSERT INTO pitr_drill_marker (marker) VALUES ('A-before-target')" >/dev/null
[ "$(psql_live "select count(*) from pitr_drill_marker where marker='A-before-target'")" = "1" ] \
  || die "could not write marker A to the live database"
ok "marker A committed"

# One second of separation, so the target timestamp is unambiguously between
# the two commits. recovery_target_time has microsecond resolution but the
# drill should not depend on that.
sleep 1
TARGET_TIME="$(psql_live "select now()")"
[ -n "${TARGET_TIME}" ] || die "could not read the target time from the server"
ok "target time: ${TARGET_TIME}"
sleep 1

psql_live "INSERT INTO pitr_drill_marker (marker) VALUES ('B-after-target')" >/dev/null
[ "$(psql_live "select count(*) from pitr_drill_marker where marker='B-after-target'")" = "1" ] \
  || die "could not write marker B to the live database"
ok "marker B committed (after the target)"

step "4. Force a WAL switch and wait for it to reach the archive"
SWITCHED_SEG="$(psql_live "select pg_walfile_name(pg_switch_wal())")"
[ -n "${SWITCHED_SEG}" ] || die "pg_switch_wal() returned nothing"
info "waiting for ${SWITCHED_SEG}"
ARCHIVED=0
for _ in $(seq 1 60); do
  # Listed from inside a container: these directories are written by the
  # database's uid, and an unreadable archive must not read as an empty one.
  if docker run --rm -v "${DS_ARCHIVE}:/wal:ro" alpine:latest \
       sh -c "test -f /wal/${SWITCHED_SEG}" 2>/dev/null; then ARCHIVED=1; break; fi
  sleep 2
done
[ "${ARCHIVED}" -eq 1 ] || die "${SWITCHED_SEG} did not reach ${DS_ARCHIVE} within 120s — the archiver is not keeping up"
ok "${SWITCHED_SEG} archived"

step "5. Recover to the target time"
"${SCRIPT_DIR}/restore-pitr.sh" \
  --dataset "${DATASET}" \
  --base "${BASE}" \
  --target-time "${TARGET_TIME}" \
  --superuser "${DS_SUPER}" \
  --workdir "${WORKDIR}/recovery" \
  --port "${PORT}" \
  --keep > "${WORKDIR}/restore.log" 2>&1
RC=$?
sed 's/^/    /' "${WORKDIR}/restore.log" | grep -E 'ok|warn|FAIL|recovery stopping|restored|replayed' | tail -12
[ ${RC} -eq 0 ] || { sed 's/^/      /' "${WORKDIR}/restore.log" | tail -25; die "restore-pitr.sh failed"; }

CONTAINER="$(docker ps --filter "publish=${PORT}" --format '{{.Names}}' | head -1)"
[ -n "${CONTAINER}" ] || die "the recovered instance is not running on port ${PORT}"

step "6. Assertions"
# -U "${DS_SUPER}", not postgres: a physical backup carries the source
# cluster's roles, and only atrocore's superuser is called postgres. Hardcoded,
# every assertion below read empty through this 2>/dev/null and the drill
# reported a working recovery as a missing table.
psql_rec() { docker exec "${CONTAINER}" psql -U "${DS_SUPER}" -d "${DS_DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# The archive must have been used. Without this the drill can pass on a base
# backup alone and prove nothing about WAL.
REPLAYED="$(docker logs "${CONTAINER}" 2>&1 | grep -ci 'restored log file' || true)"
if [ "${REPLAYED}" -gt 0 ]; then
  ok "${REPLAYED} segment(s) replayed from the archive"
else
  no "no WAL was replayed from the archive — this proved the base backup, not point-in-time recovery"
fi

HAS_TABLE="$(psql_rec "select count(*) from information_schema.tables where table_name='pitr_drill_marker'")"
if [ "${HAS_TABLE}" = "1" ]; then
  ok "the drill table exists in the recovered database"
else
  no "the drill table is absent — recovery stopped before marker A's transaction"
fi

A_COUNT="$(psql_rec "select count(*) from pitr_drill_marker where marker='A-before-target'")"
if [ "${A_COUNT}" = "1" ]; then
  ok "marker A (before the target) is present"
else
  no "marker A is missing — recovery stopped too early (got '${A_COUNT}')"
fi

B_COUNT="$(psql_rec "select count(*) from pitr_drill_marker where marker='B-after-target'")"
if [ "${B_COUNT}" = "0" ]; then
  ok "marker B (after the target) is ABSENT — replay stopped at the target"
else
  no "marker B is present — recovery ran past the target time, so this is not a point-in-time recovery"
fi

STOPPED="$(docker logs "${CONTAINER}" 2>&1 | grep -i 'recovery stopping' | tail -1)"
if [ -n "${STOPPED}" ]; then
  ok "server reported its stopping point"
  info "${STOPPED##*LOG:  }"
else
  no "the server never logged a recovery stopping point — it replayed to the end of the archive instead of to the target"
fi

step "7. The live database is untouched"
LIVE_B="$(psql_live "select count(*) from pitr_drill_marker where marker='B-after-target'")"
if [ "${LIVE_B}" = "1" ]; then
  ok "marker B is still present in the live database — recovery happened beside it, not over it"
else
  no "marker B is missing from the LIVE database — the recovery wrote over the running cluster"
fi

if [ "${KEEP}" -eq 1 ]; then
  warn "--keep: the recovered instance is left on port ${PORT} and ${WORKDIR} is not removed"
  warn "remove with: docker rm -f ${CONTAINER} && sudo rm -rf ${WORKDIR}"
else
  docker rm -f "${CONTAINER}" >/dev/null 2>&1
fi

echo ""
if [ "${FAILED}" -gt 0 ]; then
  printf '%s%d passed, %d FAILED%s\n' "${RED}" "${PASS}" "${FAILED}" "${RST}"
  exit 1
fi
printf '%s%d passed, 0 failed — %s recovers to a point in time from base backup + archived WAL%s\n' "${GRN}" "${PASS}" "${DATASET}" "${RST}"
