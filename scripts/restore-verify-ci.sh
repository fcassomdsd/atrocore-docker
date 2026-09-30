#!/usr/bin/env bash
#
# restore-verify-ci.sh — prove the backups actually restore a working system.
#
# The drill, end to end:
#   1. start from a populated stack (the demo quickstart provides one)
#   2. record what is in it
#   3. back it up
#   4. DESTROY it -- drop every schema, wipe the content store, destroy the
#      search index
#   5. restore from the backup
#   6. prove the data came back
#   7. wait for search, then prove the system WORKS
#
# Step 4 is the point. A backup that has never been restored is a file, not a
# recovery plan, and "the dump is non-empty" -- which is all CI checked before
# this -- says nothing about whether it restores. This is what turns the
# RPO/RTO numbers in "An ideal production configuration.md" section 5.2 from
# aspiration into measurement.
#
# THE SEARCH INDEX IS DESTROYED TOO, AND THAT CHANGED THE FINAL CHECK
#
# Solr is derived state and deliberately not backed up, so after a real
# disaster it does not exist. This drill used to leave the existing index in
# place, which meant the restored system had search working for reasons the
# backup had nothing to do with -- and left the last step with nowhere to put
# an assertion. It could only TOLERATE a partially failing smoke matrix,
# because it had no way to tell an index still catching up from one that
# never would.
#
# Destroying the index removes the ambiguity. The drill now waits for Alfresco
# to rebuild it to the size recorded before the destroy, and then requires the
# gateway smoke matrix to PASS. See scripts/solr-index.lib.sh; the same
# functions measure the recovery time in measure-rto.sh.
#
#   ./scripts/restore-verify-ci.sh [--assume-populated]
#
#   --assume-populated  skip step 1; the stack is already up and seeded.
#                       Used when chaining after demo-verify-ci.sh.
#
# DESTRUCTIVE. Only ever run this against a throwaway workspace.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE="${DEMO_WORKSPACE:-$(cd "${REPO_DIR}/.." && pwd)}"
DEMO_HOST="${DEMO_HOST:-localhost}"
ASSUME_POPULATED=0
[ "${1:-}" = "--assume-populated" ] && ASSUME_POPULATED=1

# shellcheck source=scripts/solr-index.lib.sh
SOLR_ENDPOINT="${SOLR_ENDPOINT:-${DEMO_HOST:-localhost}:8083}"
. "${SCRIPT_DIR}/solr-index.lib.sh"

step() { printf '\n=== %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
die()  { printf '    FAIL %s\n' "$1" >&2; exit 1; }

env_var() { [ -f "$1" ] && sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n1 | tr -d '"'"'"' \t'; }

ATRO_USER="$(env_var "${REPO_DIR}/.env" POSTGRES_PIM_USER)"
ATRO_DB="$(env_var "${REPO_DIR}/.env" POSTGRES_PIM_DB)"
WEB_USER="$(env_var "${WORKSPACE}/compliance_web/.env" POSTGRES_USER)"
WEB_DB="$(env_var "${WORKSPACE}/compliance_web/.env" POSTGRES_DB)"

psql_at() { # psql_at <dir> <service> <user> <db> <sql>
  ( cd "$1" && docker compose exec -T "$2" psql -U "$3" -d "$4" -tAc "$5" ) 2>/dev/null | tr -d '[:space:]'
}
table_count() { psql_at "$1" "$2" "$3" "$4" "select count(*) from information_schema.tables where table_schema='public'"; }

# ---------------------------------------------------------------------------
if [ "${ASSUME_POPULATED}" -eq 0 ]; then
  step "1. Populate — bring the stack up and run the demo"
  "${SCRIPT_DIR}/demo-verify-ci.sh" || die "could not produce a populated system to back up"
  ok "stack up and seeded"
else
  step "1. Populate — skipped (--assume-populated)"
fi

# ---------------------------------------------------------------------------
step "2. Record the before state"
BEFORE_ATRO="$(table_count "${REPO_DIR}" db "${ATRO_USER}" "${ATRO_DB}")"
BEFORE_ALF="$(table_count "${WORKSPACE}/compliance_cmis" postgres alfresco alfresco)"
BEFORE_WEB="$(table_count "${WORKSPACE}/compliance_web" db "${WEB_USER}" "${WEB_DB}")"
BEFORE_CONTENT="$(docker run --rm -v "${WORKSPACE}/compliance_cmis/data/alf_data:/d:ro" alpine:latest \
                    sh -c 'find /d -type f | wc -l' 2>/dev/null | tr -d '[:space:]')"
# A row that the demo definitely created, so this proves DATA came back and
# not merely that the schema did.
BEFORE_FINDING="$(psql_at "${REPO_DIR}" db "${ATRO_USER}" "${ATRO_DB}" \
  "select count(*) from inspection where code='AV-ZZZZ-A-0001'")"
echo "    atrocore tables=${BEFORE_ATRO}  alfresco tables=${BEFORE_ALF}  web tables=${BEFORE_WEB}"
echo "    content files=${BEFORE_CONTENT}  demo inspection rows=${BEFORE_FINDING}"
[ "${BEFORE_ATRO:-0}" -gt 0 ] || die "nothing to back up — AtroCore database is empty"
[ "${BEFORE_CONTENT:-0}" -gt 0 ] || die "nothing to back up — content store is empty"

# The index size becomes the target the rebuilt index must reach in step 7,
# so it is read only once Solr has stopped moving -- a count taken while the
# demo's own imports are still being indexed is a target that was never the
# real size of anything.
SOLR_SECRET_VALUE="$(solr_secret "${WORKSPACE}/compliance_cmis")"
solr_wait_indexed "${SOLR_SECRET_VALUE}" 1 600 30 \
  || die "Solr never caught up with the populated stack — cannot record an index size to restore to"
BEFORE_INDEX="$(solr_index_nodes "${SOLR_SECRET_VALUE}")"
case "${BEFORE_INDEX}" in ''|*[!0-9]*) die "could not read Solr's index size" ;; esac
[ "${BEFORE_INDEX}" -gt 0 ] || die "Solr's index is empty before the drill — there would be nothing to prove"
echo "    solr index nodes=${BEFORE_INDEX}"
ok "before state recorded"

# ---------------------------------------------------------------------------
step "3. Back up"
BACKUP_ROOT="${BACKUP_DIR:-${WORKSPACE}/backups}"
BACKUP_DIR="${BACKUP_ROOT}" "${SCRIPT_DIR}/backup-platform.sh" --yes --retention-days 0 \
  || die "backup failed"
SET_DIR="$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
[ -n "${SET_DIR}" ] || die "no backup set produced"
ok "backup set: ${SET_DIR}"

# ---------------------------------------------------------------------------
# The offsite leg, when a destination is configured.
#
# Without it this drill proves that a set taken on this host restores on this
# host -- which is a real property, and not the one that matters when the
# host is gone. With it, the set is pushed offsite, pulled back into a
# DIFFERENT directory, the local copy is deleted, and the restore consumes
# only what came back. That is the claim an offsite backup actually makes.
#
# Deleting the local set is the part that makes it honest: leaving it in
# place, a restore could read the wrong directory and nobody would know the
# offsite copy had never been exercised.
#
# Skipped silently when BACKUP_DESTINATION is unset, so the original drill
# behaves exactly as before.
if [ -n "${BACKUP_DESTINATION:-}" ]; then
  step "3b. Round-trip the set through the offsite destination"
  SET_ID="$(basename "${SET_DIR}")"

  BACKUP_DIR="${BACKUP_ROOT}" "${SCRIPT_DIR}/backup-offsite.sh" push --set "${SET_DIR}" \
    || die "offsite push failed"

  # Outside BACKUP_ROOT deliberately. Anything inside it is subject to
  # backup-platform.sh's retention sweep and to "newest directory here is
  # the set" discovery, and a restore source that another tool may prune or
  # mistake for a backup set is not a restore source.
  PULLED="${WORKSPACE}/restore-pulled/${SET_ID}"
  rm -rf "${PULLED}"
  BACKUP_DIR="${BACKUP_ROOT}" "${SCRIPT_DIR}/backup-offsite.sh" pull "${SET_ID}" --into "${PULLED}" \
    || die "offsite pull failed"

  # Gone, so the restore cannot silently fall back to it.
  rm -rf "${SET_DIR}"
  [ -d "${SET_DIR}" ] && die "could not remove the local set; refusing to continue"

  SET_DIR="${PULLED}"
  ok "restoring from the offsite copy at ${SET_DIR}"
else
  ok "no BACKUP_DESTINATION set — restoring from the local set (offsite leg skipped)"
fi

# ---------------------------------------------------------------------------
step "4. DESTROY — this is the part that makes the drill meaningful"
( cd "${WORKSPACE}/compliance_cmis" && docker compose stop alfresco >/dev/null 2>&1 )
ok "Alfresco stopped (its content store cannot be replaced underneath it)"

VOLS="$(solr_destroy_index "${WORKSPACE}/compliance_cmis")" \
  || die "could not destroy the Solr index — a drill that restores onto a working index proves less than it appears to"
ok "Solr index destroyed (${VOLS} volume(s) confirmed gone) — the state a real recovery starts from"

# Dropping the public schema needs an owner, not the application user.
# atrocore-docker's app user (POSTGRES_PIM_USER) is created by an initdb
# script and does not own the schema -- the drop fails with "must be owner of
# schema public". The other two stacks set POSTGRES_USER, which initdb makes a
# superuser, so there the app user and the owner are the same account.
# Ownership is handed back after recreating the schema, or the restore has
# nowhere to put anything.
for spec in "${REPO_DIR}|db|postgres|${ATRO_DB}|${ATRO_USER}" \
            "${WORKSPACE}/compliance_cmis|postgres|alfresco|alfresco|alfresco" \
            "${WORKSPACE}/compliance_web|db|${WEB_USER}|${WEB_DB}|${WEB_USER}"; do
  IFS='|' read -r d s owner b appuser <<< "${spec}"
  # stderr is deliberately NOT suppressed here: a destroy that silently fails
  # is the one thing that would let a restore appear to succeed against data
  # that was never removed.
  err="$( ( cd "$d" && docker compose exec -T "$s" psql -U "$owner" -d "$b" -v ON_ERROR_STOP=1 -tAc \
    "drop schema public cascade; create schema public; alter schema public owner to \"${appuser}\"; grant all on schema public to \"${appuser}\";" ) 2>&1 )" \
    || die "$(basename "$d") drop failed: ${err}"
  n="$(table_count "$d" "$s" "${appuser}" "$b")"
  [ "${n:-0}" -eq 0 ] || die "$(basename "$d") database still has ${n} tables after the drop"
done
ok "all three databases dropped to zero tables"

docker run --rm -v "${WORKSPACE}/compliance_cmis/data/alf_data:/d" alpine:latest \
  sh -c 'rm -rf /d/* /d/.[!.]* 2>/dev/null; true'
GONE="$(docker run --rm -v "${WORKSPACE}/compliance_cmis/data/alf_data:/d:ro" alpine:latest \
          sh -c 'find /d -type f | wc -l' | tr -d '[:space:]')"
[ "${GONE:-1}" -eq 0 ] || die "content store still has ${GONE} files after the wipe"
ok "content store wiped (0 files)"

# ---------------------------------------------------------------------------
step "5. Restore"
# Timed, and the timings kept as a CI artifact. This drill answers "does the
# backup restore a working system"; it is not an RTO, because it neither
# destroys Solr's index nor waits for search to be correct -- see step 7's
# tolerance for a partially failing smoke matrix, and scripts/measure-rto.sh,
# which does both and measures the whole window. What lands here is the
# data-restore half of that number, per phase, per run, so it can be trended
# instead of remeasured from scratch each time someone asks.
RTO_RECORD="${RTO_RECORD:-${REPO_DIR}/rto-measurements.jsonl}" \
  "${SCRIPT_DIR}/restore-platform.sh" --from "${SET_DIR}" --yes || die "restore failed"
( cd "${WORKSPACE}/compliance_cmis" && docker compose up -d alfresco solr6 >/dev/null 2>&1 )
ok "Alfresco and a blank Solr started"

# ---------------------------------------------------------------------------
step "6. Prove it came back"
AFTER_ATRO="$(table_count "${REPO_DIR}" db "${ATRO_USER}" "${ATRO_DB}")"
AFTER_ALF="$(table_count "${WORKSPACE}/compliance_cmis" postgres alfresco alfresco)"
AFTER_WEB="$(table_count "${WORKSPACE}/compliance_web" db "${WEB_USER}" "${WEB_DB}")"
AFTER_CONTENT="$(docker run --rm -v "${WORKSPACE}/compliance_cmis/data/alf_data:/d:ro" alpine:latest \
                   sh -c 'find /d -type f | wc -l' | tr -d '[:space:]')"
AFTER_FINDING="$(psql_at "${REPO_DIR}" db "${ATRO_USER}" "${ATRO_DB}" \
  "select count(*) from inspection where code='AV-ZZZZ-A-0001'")"

cmp_val() { # cmp_val <label> <before> <after>
  if [ "${2:-x}" = "${3:-y}" ]; then ok "$1: ${3} (matches pre-backup)"
  else die "$1: ${3} after restore, expected ${2}"; fi
}
cmp_val "AtroCore tables"      "${BEFORE_ATRO}"    "${AFTER_ATRO}"
cmp_val "Alfresco tables"      "${BEFORE_ALF}"     "${AFTER_ALF}"
cmp_val "compliance_web tables" "${BEFORE_WEB}"    "${AFTER_WEB}"
cmp_val "content store files"  "${BEFORE_CONTENT}" "${AFTER_CONTENT}"
cmp_val "demo inspection rows" "${BEFORE_FINDING}" "${AFTER_FINDING}"

step "7. Does the restored system actually work?"
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-" || true)"
  [ "${code}" = "200" ] && break
  sleep 5
done
[ "${code}" = "200" ] || die "Alfresco did not become ready after the restore"
ok "Alfresco ready (${i} attempt(s))"

# Search has to be correct before the smoke matrix means anything. The index
# was destroyed in step 4, so this is a full rebuild from the restored
# database -- which is exactly what happens after a real recovery, and is
# the part of recovery time that scales with the dataset (see
# scripts/measure-rto.sh).
solr_wait_indexed "${SOLR_SECRET_VALUE}" "${BEFORE_INDEX}" 1800 30 \
  || die "Solr did not rebuild to ${BEFORE_INDEX} nodes within 30m — search-backed reads would still be wrong"
AFTER_INDEX="$(solr_index_nodes "${SOLR_SECRET_VALUE}")"
# The low-water mark proves the index was genuinely rebuilt rather than never
# emptied: without it, an index the destroy failed to remove satisfies the
# target on the first poll and this reports a rebuild that never happened.
[ "${SOLR_LOW_WATER}" -lt "${BEFORE_INDEX}" ] \
  || die "the index never dropped below its original size (${SOLR_LOW_WATER}) — it was not rebuilt, so search proves nothing here"
ok "search index rebuilt: ${AFTER_INDEX} nodes (was ${BEFORE_INDEX}, low-water ${SOLR_LOW_WATER})"

if [ -f "${WORKSPACE}/compliance_flow/scripts/smoke-flows.mjs" ]; then
  # The harness reads API_KEY from the environment. Pass it explicitly rather
  # than sourcing the .env: `set -a; . .env` also exports COMPOSE_* and
  # redirects every later docker compose call, which is a bug already fixed
  # once in demo-quickstart.sh.
  SMOKE_OUT="$(cd "${WORKSPACE}/compliance_flow" \
    && API_KEY="$(env_var "${WORKSPACE}/compliance_flow/.env" API_KEY)" \
       node scripts/smoke-flows.mjs 2>&1)"
  SMOKE_RC=$?
  echo "${SMOKE_OUT}" | tail -3 | sed 's/^/    /'

  if [ "${SMOKE_RC}" -eq 0 ]; then
    ok "gateway smoke matrix passed against the restored system"
  elif echo "${SMOKE_OUT}" | grep -q "X-API-Key header is required"; then
    # Do not dress this up as search lag. A blanket 401 means the harness was
    # run without a key -- the check did not exercise the restored system at
    # all, and reporting it as an expected Solr delay would be a diagnostic
    # that lies about its own failure.
    die "smoke matrix could not authenticate (401) — the check did not run; this says nothing about the restore"
  elif echo "${SMOKE_OUT}" | grep -qE "0 passed"; then
    die "smoke matrix passed nothing — the restored system is not serving"
  else
    # This used to be tolerated as "expected while Solr reindexes". It no
    # longer can be: the index was destroyed deliberately in step 4 and step 7
    # waited for it to be rebuilt to the size recorded before the destroy, so
    # search lag is no longer an available explanation for a failing probe.
    # Anything still failing here is the restored system failing.
    echo "${SMOKE_OUT}" | tail -20 | sed 's/^/      /'
    die "smoke matrix failed after the index finished rebuilding — this is not search lag, the restored system does not work"
  fi
fi

printf '\nrestore-verify: the backup restored a working system\n'
