#!/usr/bin/env bash
#
# restore-pitr.sh — recover one database to a point in time, into a scratch
# instance beside the live one.
#
#   ./scripts/restore-pitr.sh --dataset atrocore \
#       --base /path/to/atrocore.basebackup.tar \
#       --target-time "2026-09-29 18:04:00+00" [--port 55432] [--keep]
#
#   --dataset      atrocore | alfresco | compliance_web
#   --base         a *.basebackup.tar from a backup set (backup-platform.sh
#                  step 1b). A pg_dump CANNOT be used: WAL replays onto a
#                  *physical* base, which is the whole reason those tars exist.
#   --target-time  where to stop, as a Postgres timestamp WITH a zone. Use
#                  --target-time latest to replay everything available.
#   --port         host port for the recovered instance (default 55432).
#   --archive      override the WAL archive directory.
#   --workdir      where to extract (default: a mktemp dir; needs ~2x the
#                  base backup's size).
#   --keep         leave the container running after a successful recovery.
#                  Without it the instance is stopped but the data directory
#                  is kept and its path printed.
#
# WHY THIS RESTORES BESIDE THE LIVE DATABASE, NEVER OVER IT
#
# A point-in-time recovery is a hypothesis: "the damage happened after T".
# Getting T wrong is normal and the first attempt is usually wrong. Restoring
# over the live cluster makes each attempt destructive and the mistake
# unrecoverable, so this brings up a SEPARATE instance on a scratch port that
# you query, compare, and only then promote by hand. Nothing here writes to
# any running service.
#
# The WAL archive is mounted READ-ONLY, and that is a correctness property
# rather than caution: the archive is the input to every future recovery, and
# a recovering server that could write into it -- by archiving its own WAL
# after promotion, on a timeline that now diverges -- would corrupt the source
# of the next attempt. Archiving is also deliberately not enabled on the
# recovered instance for the same reason.
#
# THE IMAGE IS READ FROM THE LIVE COMPOSE FILE, NOT HARDCODED
#
# A base backup is a physical copy of a data directory and can only be read by
# the same PostgreSQL major version that wrote it. The three databases here are
# on 15, 16.5 and 16, so a hardcoded image would silently be wrong for two of
# them: PostgreSQL refuses with "database files are incompatible with server",
# which is the good case. Resolving it from `docker compose config` keeps this
# correct when an image is bumped.
#
# WHAT A SUCCESSFUL RUN PROVES, AND WHAT IT DOES NOT
#
# It proves the base backup and the archived WAL together reconstruct the
# database as of a chosen moment. It does NOT prove the rest of the platform
# recovers with it: the Alfresco content store is not WAL-protected and has to
# come from the same set's alf_data.tar.gz, and a database recovered to a time
# the content store does not match will hold references to files that are not
# there. For whole-platform recovery use restore-platform.sh; this tool is for
# rewinding one database past a bad write.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"

DATASET=""
BASE=""
TARGET_TIME=""
PORT=55432
ARCHIVE=""
WORKDIR=""
KEEP=0

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; BLD=""; RST=""; }

step() { printf '\n%s==> %s%s\n' "${BLD}" "$*" "${RST}"; }
ok()   { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; }
warn() { printf '    %swarn%s %s\n' "${YEL}" "${RST}" "$*"; }
die()  { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dataset)     DATASET="${2:-}"; shift 2 ;;
    --base)        BASE="${2:-}"; shift 2 ;;
    --target-time) TARGET_TIME="${2:-}"; shift 2 ;;
    --port)        PORT="${2:-}"; shift 2 ;;
    --archive)     ARCHIVE="${2:-}"; shift 2 ;;
    --workdir)     WORKDIR="${2:-}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "${DATASET}" ]     || die "--dataset is required (atrocore | alfresco | compliance_web)"
[ -n "${BASE}" ]        || die "--base is required (a *.basebackup.tar from a backup set)"
[ -n "${TARGET_TIME}" ] || die "--target-time is required (a timestamp with a zone, or 'latest')"
[ -f "${BASE}" ]        || die "base backup not found: ${BASE}"

# --- dataset table ---------------------------------------------------------
# Kept here rather than derived, because the archive paths are the ones the
# compose files bind-mount and getting one wrong recovers the wrong database
# into a plausible-looking result.
case "${DATASET}" in
  atrocore)
    DS_DIR="${REPO_DIR}"; DS_SVC="db"
    DS_ARCHIVE="${REPO_DIR}/wal-archive" ;;
  alfresco)
    DS_DIR="${WORKSPACE}/compliance_cmis"; DS_SVC="postgres"
    DS_ARCHIVE="${WORKSPACE}/compliance_cmis/data/wal-archive" ;;
  compliance_web)
    DS_DIR="${WORKSPACE}/compliance_web"; DS_SVC="db"
    DS_ARCHIVE="${WORKSPACE}/compliance_web/data/wal-archive" ;;
  *) die "unknown dataset: ${DATASET} (expected atrocore | alfresco | compliance_web)" ;;
esac
[ -n "${ARCHIVE}" ] && DS_ARCHIVE="${ARCHIVE}"

command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"

step "1. Resolve the PostgreSQL image for '${DATASET}'"
[ -d "${DS_DIR}" ] || die "repository not found: ${DS_DIR} — this tool expects the six repos side by side"
# PITR_ENV_FILE, same convention as verify-wal-archiving.sh's WAL_ENV_FILE:
# CI checkouts have no .env, and `docker compose config` against a compose
# file whose variables are unset resolves to something other than what runs.
COMPOSE=(docker compose)
[ -n "${PITR_ENV_FILE:-}" ] && COMPOSE=(docker compose --env-file "${PITR_ENV_FILE}")
IMAGE="$(cd "${DS_DIR}" && "${COMPOSE[@]}" config --format json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['services']['${DS_SVC}']['image'])" 2>/dev/null)"
[ -n "${IMAGE}" ] || die "could not read the image for service '${DS_SVC}' from ${DS_DIR} — a base backup restored by the wrong major version is unusable, so this refuses to guess"
ok "image: ${IMAGE}"

step "2. Check the WAL archive"
[ -d "${DS_ARCHIVE}" ] || die "WAL archive not found: ${DS_ARCHIVE}"
# Counted in a container: these directories are written by the database's uid
# and are not always readable by the invoking user, which would make an
# unreadable archive look like an empty one.
SEGMENTS="$(docker run --rm -v "${DS_ARCHIVE}:/wal:ro" alpine:latest \
  sh -c 'find /wal -type f 2>/dev/null | wc -l' | tr -d ' ')"
case "${SEGMENTS}" in ''|*[!0-9]*) die "could not list ${DS_ARCHIVE} — refusing to treat an unreadable archive as an empty one" ;; esac
[ "${SEGMENTS}" -gt 0 ] || die "${DS_ARCHIVE} holds no WAL segments — there is nothing to replay"
ok "${SEGMENTS} segment(s) in ${DS_ARCHIVE} (mounted read-only)"

step "3. Extract the base backup"
if [ -z "${WORKDIR}" ]; then
  WORKDIR="$(mktemp -d -t pitr-XXXXXX)"
fi
mkdir -p "${WORKDIR}" || die "cannot create ${WORKDIR}"
PGDATA_DIR="${WORKDIR}/pgdata"
# Removed from inside a container. A previous run left this owned by uid 999
# and mode 0700, so a host-side `rm -rf` fails with Permission denied -- and
# quietly, since rm's failure would not stop the extraction from unpacking on
# top of a stale cluster.
if [ -e "${PGDATA_DIR}" ]; then
  docker run --rm -v "${WORKDIR}:/w" alpine:latest rm -rf /w/pgdata \
    || die "could not clear ${PGDATA_DIR} from a previous run"
fi
mkdir -p "${PGDATA_DIR}"

# Extracted inside a container, then chowned to the image's postgres uid (999).
# Unpacking as the invoking user leaves uid 1000 files that the server cannot
# read, and PostgreSQL additionally refuses to start on a data directory whose
# mode is not 0700.
docker run --rm -v "${BASE}:/base.tar:ro" -v "${PGDATA_DIR}:/pgdata" alpine:latest \
  sh -c 'tar xf /base.tar -C /pgdata && chown -R 999:999 /pgdata && chmod 700 /pgdata' \
  || die "could not extract ${BASE}"
# Checked inside a container, not with `[ -f ... ]`. The extraction just made
# this directory mode 0700 owned by uid 999 -- which PostgreSQL requires -- so
# the invoking user cannot stat through it and a host-side test reports a
# perfectly good base backup as malformed. Exactly the failure the WAL count
# above guards against, one step later.
PGVER="$(docker run --rm -v "${PGDATA_DIR}:/d:ro" alpine:latest \
  sh -c 'cat /d/PG_VERSION 2>/dev/null' | tr -d '[:space:]')"
[ -n "${PGVER}" ] || die "${BASE} does not look like a base backup — no PG_VERSION after extraction"
ok "extracted to ${PGDATA_DIR} (PG_VERSION ${PGVER})"

step "4. Configure recovery"
# recovery.signal is what puts the server into archive recovery; without it the
# settings below are read and ignored, and the server starts as an ordinary
# cluster at the base backup's own end point -- a silent wrong answer that
# looks exactly like a successful recovery.
if [ "${TARGET_TIME}" = "latest" ]; then
  TARGET_CLAUSE=""
  ok "target: latest (replay every segment available)"
else
  TARGET_CLAUSE="recovery_target_time = '${TARGET_TIME}'"
  ok "target: ${TARGET_TIME}"
fi

RECOVERY_CONF="$(cat <<CONF
# written by restore-pitr.sh
restore_command = 'cp /wal-archive/%f %p'
${TARGET_CLAUSE}
recovery_target_action = 'promote'
# Deliberately NOT archiving: this instance's timeline diverges at the
# recovery target, and letting it write into the archive would corrupt the
# input to every later recovery.
archive_mode = off
CONF
)"
docker run --rm -v "${PGDATA_DIR}:/pgdata" alpine:latest sh -c \
  "printf '%s\n' \"\$1\" >> /pgdata/postgresql.auto.conf && touch /pgdata/recovery.signal && chown 999:999 /pgdata/postgresql.auto.conf /pgdata/recovery.signal" \
  -- "${RECOVERY_CONF}" || die "could not write the recovery configuration"
ok "recovery.signal written, restore_command set, archiving disabled"

step "5. Start the recovery instance on port ${PORT}"
CONTAINER="pitr-${DATASET}-$$"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
  -v "${PGDATA_DIR}:/var/lib/postgresql/data" \
  -v "${DS_ARCHIVE}:/wal-archive:ro" \
  -e POSTGRES_PASSWORD=pitr-scratch-not-a-credential \
  -p "127.0.0.1:${PORT}:5432" \
  "${IMAGE}" >/dev/null || die "could not start the recovery container"
ok "container ${CONTAINER} started"

cleanup_on_failure() {
  echo ""
  echo "  recovery log (last 40 lines):"
  docker logs "${CONTAINER}" 2>&1 | tail -40 | sed 's/^/      /'
  echo ""
  # The most common way this fails is asking for a time the archive cannot
  # reach: PostgreSQL replays everything it has, then refuses with "recovery
  # ended before configured recovery target was reached" rather than quietly
  # giving you the wrong database. The answer to "what CAN I recover to" is in
  # the log it just printed, so point at it rather than making it be hunted.
  if docker logs "${CONTAINER}" 2>&1 | grep -q 'recovery ended before configured recovery target'; then
    local latest
    latest="$(docker logs "${CONTAINER}" 2>&1 | grep -o 'last completed transaction was at log time.*' | tail -1)"
    echo "  The target is beyond the end of the archived WAL."
    [ -n "${latest}" ] && echo "  ${latest}"
    echo "  Re-run with --target-time at or before that, or with --target-time latest."
    echo ""
  fi
  echo "  the container and ${PGDATA_DIR} are left in place for inspection."
  echo "  remove with: docker rm -f ${CONTAINER} && rm -rf ${WORKDIR}"
}

step "6. Wait for recovery to finish"
# Recovery is complete when the server accepts connections AND is no longer in
# recovery. pg_isready alone is not enough: a server still replaying answers
# it while refusing queries, so a check that stops there reports success
# partway through the replay.
RECOVERED=0
for _ in $(seq 1 120); do
  if docker exec "${CONTAINER}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
    IN_RECOVERY="$(docker exec "${CONTAINER}" psql -U postgres -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '[:space:]')"
    if [ "${IN_RECOVERY}" = "f" ]; then RECOVERED=1; break; fi
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" != "true" ]; then
    cleanup_on_failure
    die "the recovery instance exited — see the log above"
  fi
  sleep 2
done
[ "${RECOVERED}" -eq 1 ] || { cleanup_on_failure; die "recovery did not complete within 240s"; }
ok "recovery complete, server promoted"

step "7. Where it stopped"
# The stopping point comes from the server's own log, not from what was asked
# for: a target later than the last archived segment recovers to the end of
# what exists and reports success, so the requested time is not evidence.
docker logs "${CONTAINER}" 2>&1 \
  | grep -iE 'recovery stopping|last completed transaction|consistent recovery state|redo done|selected new timeline|starting point-in-time recovery' \
  | sed 's/^/    /' || true

# How much WAL was actually replayed FROM THE ARCHIVE, which is the only part
# of this that the archive proves anything about. A base backup taken with -Xf
# carries the WAL it needs to reach consistency, so a recovery that fetches
# nothing still reaches "recovery complete, server promoted" and looks
# identical to a working one. The first run of this script did exactly that --
# redo done at the consistency point, 0.00s elapsed -- and only the segment
# count distinguished it from a real replay.
REPLAYED="$(docker logs "${CONTAINER}" 2>&1 | grep -ci 'restored log file' || true)"
if [ "${REPLAYED}" -gt 0 ]; then
  ok "${REPLAYED} WAL segment(s) replayed from the archive"
else
  warn "NO WAL was replayed from the archive — this recovery used only the WAL bundled in the base backup."
  warn "That is correct when nothing was committed after the backup, and meaningless as evidence that the archive works."
fi
LAST_XACT="$(docker exec "${CONTAINER}" psql -U postgres -tAc 'select pg_last_committed_xact()' 2>/dev/null | tr -d '[:space:]')"
[ -n "${LAST_XACT}" ] && ok "pg_last_committed_xact: ${LAST_XACT}"

step "8. Recovered instance"
echo ""
echo "    host      127.0.0.1"
echo "    port      ${PORT}"
echo "    data dir  ${PGDATA_DIR}"
echo "    container ${CONTAINER}"
echo ""
echo "    Inspect it, for example:"
echo "      psql -h 127.0.0.1 -p ${PORT} -U postgres -l"
echo ""
echo "    This is a SEPARATE instance. Nothing has been written to the live"
echo "    database. Promote by dumping from here and restoring deliberately."
echo ""

if [ "${KEEP}" -eq 1 ]; then
  ok "left running (--keep). Remove with: docker rm -f ${CONTAINER} && rm -rf ${WORKDIR}"
else
  docker stop "${CONTAINER}" >/dev/null 2>&1
  docker rm "${CONTAINER}" >/dev/null 2>&1
  ok "container stopped and removed; the recovered data directory is kept at ${PGDATA_DIR}"
  echo "    restart it with:"
  echo "      docker run -d --name pitr-${DATASET} -v ${PGDATA_DIR}:/var/lib/postgresql/data -p 127.0.0.1:${PORT}:5432 ${IMAGE}"
  echo "    remove it with:"
  echo "      rm -rf ${WORKDIR}"
fi

echo ""
printf '%sPITR complete: %s recovered to %s%s\n' "${GRN}" "${DATASET}" "${TARGET_TIME}" "${RST}"
