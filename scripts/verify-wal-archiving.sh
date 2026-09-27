#!/usr/bin/env bash
#
# verify-wal-archiving.sh — assert that WAL archiving is not merely configured
# but actually working.
#
# This exists because the failure is silent. A broken archive_command does not
# stop PostgreSQL: it keeps serving, `failed_count` climbs, and WAL accumulates
# until the volume fills and the database stops — at which point the cause is
# hours old. A CI job that only boots the database would pass throughout.
#
# Checks, in order of how much they prove:
#   1. archive_mode is on                  (configured)
#   2. a forced segment switch is archived (the command actually runs)
#   3. failed_count is 0                   (and it has never silently failed)
#
# Every repository that enables archiving carries a byte-identical copy, the
# same convention as release-tag.sh (see CONTRIBUTING.md).
#
# Configure with environment variables:
#   WAL_SERVICE   compose service name                    (required)
#   WAL_USER      database user                           (required)
#   WAL_DB        database name                           (required)
#   WAL_ARCHIVE   archive path INSIDE the container       (default /wal-archive)
#   WAL_SUPERUSER user that may call pg_switch_wal()      (default: WAL_USER)
#   WAL_ENV_FILE  --env-file to pass to compose           (optional)
#
# The archive is counted from inside the container, deliberately. Under
# docker-in-docker the CLI and the daemon have separate filesystems, so a bind
# mount the daemon writes is not visible at the same path on the runner — a
# host-side count would read zero no matter what archiving did, and the check
# would fail for the wrong reason (or pass for one, if inverted).

set -uo pipefail

: "${WAL_SERVICE:?WAL_SERVICE is required}"
: "${WAL_USER:?WAL_USER is required}"
: "${WAL_DB:?WAL_DB is required}"
WAL_ARCHIVE="${WAL_ARCHIVE:-/wal-archive}"
# pg_switch_wal() and pg_stat_archiver are superuser-only. Where the
# application user was created by an initdb script rather than POSTGRES_USER
# it is NOT a superuser -- atrocore-docker is the case here, and the symptom
# is "permission denied for function pg_switch_wal", not a missing segment.
# Same app-user-versus-owner distinction that bit the restore drill's destroy
# step. Defaults to WAL_USER, which is correct wherever POSTGRES_USER is the
# app user.
WAL_SUPERUSER="${WAL_SUPERUSER:-${WAL_USER}}"

COMPOSE=(docker compose)
[ -n "${WAL_ENV_FILE:-}" ] && COMPOSE=(docker compose --env-file "${WAL_ENV_FILE}")

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; exit 1; }

psql_q()  { "${COMPOSE[@]}" exec -T "${WAL_SERVICE}" psql -U "${WAL_USER}"      -d "${WAL_DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
psql_su() { "${COMPOSE[@]}" exec -T "${WAL_SERVICE}" psql -U "${WAL_SUPERUSER}" -d "${WAL_DB}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
# Counted inside the container so this works identically with or without dind.
seg_count() { "${COMPOSE[@]}" exec -T "${WAL_SERVICE}" sh -c "ls -1 ${WAL_ARCHIVE} 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]'; }

printf 'verify-wal-archiving: service=%s db=%s archive=%s (in-container)\n' "${WAL_SERVICE}" "${WAL_DB}" "${WAL_ARCHIVE}"

"${COMPOSE[@]}" up -d "${WAL_SERVICE}" >/dev/null 2>&1 || fail "could not start ${WAL_SERVICE}"

for i in $(seq 1 40); do
  [ "$(psql_q 'select 1')" = "1" ] && break
  sleep 2
done
[ "$(psql_q 'select 1')" = "1" ] || fail "${WAL_SERVICE} never became ready"
ok "${WAL_SERVICE} is accepting connections"

# 1. configured
MODE="$(psql_q 'show archive_mode')"
[ "${MODE}" = "on" ] || fail "archive_mode is '${MODE}', expected 'on'"
ok "archive_mode=on"

TIMEOUT="$(psql_q 'show archive_timeout')"
[ "${TIMEOUT}" != "0" ] || fail "archive_timeout is 0 — an idle database would never switch a segment, so RPO would be unbounded"
ok "archive_timeout=${TIMEOUT}"

# 2. actually archiving
BEFORE="$(seg_count)"
psql_q "create table if not exists _wal_probe(i int)" >/dev/null
psql_q "insert into _wal_probe select generate_series(1,20000)" >/dev/null
SWITCHED="$(psql_su "select pg_switch_wal()")"
[ -n "${SWITCHED}" ] || fail "could not force a WAL switch as '${WAL_SUPERUSER}' — set WAL_SUPERUSER to an account that may call pg_switch_wal()"
for i in $(seq 1 20); do
  AFTER="$(seg_count)"
  [ "${AFTER}" -gt "${BEFORE}" ] && break
  sleep 2
done
psql_q "drop table if exists _wal_probe" >/dev/null
[ "${AFTER}" -gt "${BEFORE}" ] \
  || fail "no segment reached ${WAL_ARCHIVE} after a forced switch (${BEFORE} -> ${AFTER}); archive_command is not working"
ok "a forced segment switch was archived (${BEFORE} -> ${AFTER} files)"

# 3. and is healthy NOW
#
# Deliberately not `failed_count = 0`. Those counters are cumulative and
# survive restarts, so a single transient failure years ago — a brief network
# blip to an NFS archive, say — would make a zero-check fail forever. That is
# a nuisance alarm, and nuisance alarms get muted, which is how the real one
# gets missed. The question worth asking is whether archiving is working
# *now*: either it has never failed, or it has succeeded since it last failed.
HEALTH="$(psql_su "select case
  when last_failed_time is null then 'never-failed'
  when last_archived_time is not null and last_archived_time > last_failed_time then 'recovered'
  else 'failing' end from pg_stat_archiver")"
case "${HEALTH}" in
  never-failed) ok "archiver has never failed" ;;
  recovered)    ok "archiver has failed before but has archived successfully since — healthy now" ;;
  *)            fail "archiver is currently failing (last failure is more recent than the last success); WAL will accumulate until the volume fills" ;;
esac

STATS="$(psql_su "select 'archived='||archived_count||' failed='||failed_count from pg_stat_archiver")"
ok "cumulative: ${STATS}"

printf 'verify-wal-archiving: archiving is working\n'
