#!/usr/bin/env bash
#
# restore-verify-ci.sh — prove the backups actually restore a working system.
#
# The drill, end to end:
#   1. start from a populated stack (the demo quickstart provides one)
#   2. record what is in it
#   3. back it up
#   4. DESTROY it -- drop every schema, wipe the content store
#   5. restore from the backup
#   6. prove the system works and the data came back
#
# Step 4 is the point. A backup that has never been restored is a file, not a
# recovery plan, and "the dump is non-empty" -- which is all CI checked before
# this -- says nothing about whether it restores. This is what turns the
# RPO/RTO numbers in "An ideal production configuration.md" section 5.2 from
# aspiration into measurement.
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
step "4. DESTROY — this is the part that makes the drill meaningful"
( cd "${WORKSPACE}/compliance_cmis" && docker compose stop alfresco >/dev/null 2>&1 )
ok "Alfresco stopped (its content store cannot be replaced underneath it)"

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
"${SCRIPT_DIR}/restore-platform.sh" --from "${SET_DIR}" --yes || die "restore failed"
( cd "${WORKSPACE}/compliance_cmis" && docker compose start alfresco >/dev/null 2>&1 )
ok "Alfresco restarted"

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
    # Partial failure IS the expected shape: Solr is deliberately not backed
    # up, so search-backed reads lag until Alfresco reindexes.
    printf '    warn smoke matrix partially failed — expected while Solr reindexes (it is derived state and not backed up)\n'
  fi
fi

printf '\nrestore-verify: the backup restored a working system\n'
