#!/usr/bin/env bash
#
# restore-platform.sh — restore a backup set produced by backup-platform.sh.
#
#   ./scripts/restore-platform.sh --from DIR [--yes] [--skip-content]
#
#   --from           the backup set directory (the one containing MANIFEST).
#   --skip-content   restore databases only, leaving the content store alone.
#   --yes            skip the confirmation prompt.
#
# THIS IS DESTRUCTIVE. It drops and recreates three databases and replaces the
# Alfresco content store. It refuses to run without --yes or an interactive
# confirmation, and it verifies every checksum in the MANIFEST before touching
# anything -- restoring half a corrupt set is worse than not starting.
#
# ORDERING, AGAIN FOR A REASON
#   Restore is the mirror of backup: content store FIRST, databases SECOND. The
#   database is the authority on what content exists, so it must be the last
#   thing to land. Putting the database first would leave a window where it
#   references content not yet written.
#
# AFTERWARDS
#   Solr is NOT restored -- it is derived state. Alfresco rebuilds the index on
#   demand, but a restored system will return incomplete search results until
#   it has. The read paths that depend on search (the checklist endpoint, open
#   findings, four report Web Scripts) are the ones to re-check first; see
#   FOOTPRINT_AUDIT.md for what fails and how when the index is unavailable.
#
#   Reindexing is therefore part of the recovery time even though it is not
#   part of this script, and on a real dataset it is the largest part. What
#   this script reports is the time to put the DATA back; scripts/measure-rto.sh
#   measures the time to get the SERVICE back, which is the number an RTO is.
#
# TIMING
#   Every phase is timed and the breakdown printed at the end. Set RTO_RECORD
#   to a file path to also append a machine-readable line. An RTO quoted from
#   a design document is a guess; this makes every restore anyone runs into a
#   data point.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
FROM=""
ASSUME_YES=0
SKIP_CONTENT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --from=*) FROM="${1#*=}"; shift ;;
    --skip-content) SKIP_CONTENT=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n=== %s\n' "$1"; }
ok()    { printf '    ok   %s\n' "$1"; }
warn()  { printf '    warn %s\n' "$1"; }
die()   { red "    FAIL $1"; exit 1; }

# --- phase timing ----------------------------------------------------------
# EPOCHREALTIME rather than `date`: this runs on Alpine in CI, where busybox
# date has no %N and would silently give whole seconds for phases measured in
# tens of milliseconds.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t="${EPOCHREALTIME/,/.}"
    echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
  else
    echo $(( SECONDS * 1000 ))
  fi
}
fmt_ms() { # 1234 -> 1.2s
  local ms="$1"
  if [ "${ms}" -lt 1000 ]; then printf '%dms' "${ms}"
  elif [ "${ms}" -lt 60000 ]; then printf '%d.%01ds' $(( ms / 1000 )) $(( (ms % 1000) / 100 ))
  else printf '%dm%02ds' $(( ms / 60000 )) $(( (ms % 60000) / 1000 )); fi
}
RUN_T0="$(now_ms)"
PHASE_NAME=""; PHASE_T0=0
declare -a PHASE_LOG=()
phase() { # phase [name] -- closes the open phase, opens `name` if given
  if [ -n "${PHASE_NAME}" ]; then
    local ms=$(( $(now_ms) - PHASE_T0 ))
    PHASE_LOG+=("${PHASE_NAME}:${ms}")
  fi
  PHASE_NAME="${1:-}"
  [ -n "${PHASE_NAME}" ] && PHASE_T0="$(now_ms)"
  return 0
}

env_var() { # env_var <file> <name> -- parse, never source (see backup-platform.sh)
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}

compose_running() { [ -d "$1" ] && ( cd "$1" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null ) | grep -qx "$2"; }

[ -n "${FROM}" ] || die "--from is required"
[ -d "${FROM}" ] || die "${FROM} is not a directory"
[ -f "${FROM}/MANIFEST" ] || die "${FROM}/MANIFEST not found — is this a backup set?"

bold "restore-platform"
echo "source: ${FROM}"
sed -n 's/^created_utc: /created: /p' "${FROM}/MANIFEST" | sed 's/^/        /'

# --- verify before touching anything --------------------------------------
phase verify
step "1. Verify the set"
bad=0
while read -r name; do
  want="$(grep -A2 "name: ${name}\$" "${FROM}/MANIFEST" | sed -n 's/.*sha256: //p' | head -1)"
  have="$(sha256sum "${FROM}/${name}" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "${have}" ]; then red "    FAIL ${name} listed in MANIFEST but missing"; bad=$((bad+1))
  elif [ "${want}" != "${have}" ]; then red "    FAIL ${name} checksum mismatch"; bad=$((bad+1))
  else ok "${name} checksum ok"; fi
# Only the `files:` section. The MANIFEST has TWO `- name:` lists -- the
# other is `wal_archives:`, which names archive directories, not files in
# this set. A line-oriented sed cannot tell them apart, so this read the
# three archive labels as missing files and refused to restore every set
# taken since WAL archiving was added. Found by running a real backup
# through the offsite push, which uses the same verification.
done < <(awk '/^files:/ {infiles=1; next} /^[^ #]/ {infiles=0} infiles && /^  - name: / {sub(/^  - name: /, ""); print}' "${FROM}/MANIFEST")
[ "${bad}" -eq 0 ] || die "${bad} file(s) failed verification — refusing to restore a corrupt set"

echo
red "This REPLACES three databases and the Alfresco content store."
if [ "${ASSUME_YES}" -ne 1 ]; then
  printf 'Type RESTORE to continue: '; read -r a; [ "$a" = "RESTORE" ] || { echo "aborted"; exit 0; }
fi

# --- content store first (mirror of the backup order) ----------------------
phase content
if [ "${SKIP_CONTENT}" -eq 0 ] && [ -f "${FROM}/alf_data.tar.gz" ]; then
  step "2. Alfresco content store"
  ALF_DATA="${WORKSPACE}/compliance_cmis/data/alf_data"
  if compose_running "${WORKSPACE}/compliance_cmis" alfresco; then
    die "Alfresco is running — stop it before restoring its content store (docker compose stop alfresco)"
  fi
  mkdir -p "${ALF_DATA}"
  docker run --rm -v "${ALF_DATA}:/dst" -v "${FROM}:/in:ro" alpine:latest \
    sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf /in/alf_data.tar.gz -C /dst' \
    || die "content store restore failed"
  ok "content store restored from alf_data.tar.gz"
else
  step "2. Alfresco content store — skipped"
fi

# --- databases second ------------------------------------------------------
phase databases
step "3. Databases"
restore_db() { # restore_db <label> <dir> <service> <user> <db> <dumpfile>
  local label="$1" dir="$2" svc="$3" user="$4" db="$5" dump="$6"
  [ -f "${dump}" ] || { warn "${label}: no dump in this set — skipped"; return; }
  compose_running "${dir}" "${svc}" || die "${label}: service '${svc}' must be running to restore into"
  # --clean --if-exists drops objects first; without it a restore into a
  # populated database silently merges and leaves rows the backup never had.
  if ( cd "${dir}" && docker compose exec -T "${svc}" pg_restore -U "${user}" -d "${db}" \
        --clean --if-exists --no-owner --no-privileges ) < "${dump}" >/dev/null 2>&1; then
    ok "${label}: restored"
  else
    # pg_restore exits non-zero on benign "does not exist" notices from
    # --clean on a fresh database, so verify by counting tables instead of
    # trusting the exit code.
    local n
    n="$( ( cd "${dir}" && docker compose exec -T "${svc}" psql -U "${user}" -d "${db}" -tAc \
          "select count(*) from information_schema.tables where table_schema='public'" ) 2>/dev/null | tr -d '[:space:]')"
    if [ "${n:-0}" -gt 0 ]; then
      ok "${label}: restored (${n} tables; pg_restore reported non-fatal notices)"
    else
      die "${label}: restore failed and the database is empty"
    fi
  fi
}

ATRO_ENV="${REPO_DIR}/.env"
restore_db "AtroCore DB" "${REPO_DIR}" db \
  "$(env_var "${ATRO_ENV}" POSTGRES_PIM_USER)" "$(env_var "${ATRO_ENV}" POSTGRES_PIM_DB)" \
  "${FROM}/atrocore.dump"

restore_db "Alfresco DB" "${WORKSPACE}/compliance_cmis" postgres alfresco alfresco \
  "${FROM}/alfresco.dump"

WEB_ENV="${WORKSPACE}/compliance_web/.env"
restore_db "compliance_web DB" "${WORKSPACE}/compliance_web" db \
  "$(env_var "${WEB_ENV}" POSTGRES_USER)" "$(env_var "${WEB_ENV}" POSTGRES_DB)" \
  "${FROM}/compliance_web.dump"

phase ""
TOTAL_MS=$(( $(now_ms) - RUN_T0 ))

step "4. How long it took"
for entry in "${PHASE_LOG[@]}"; do
  printf '    %-12s %s\n' "${entry%%:*}" "$(fmt_ms "${entry##*:}")"
done
printf '    %-12s %s\n' "TOTAL" "$(fmt_ms "${TOTAL_MS}")"
echo "    (data restored. Search-backed reads are NOT yet correct — see below.)"

# Machine-readable, one line per run, so a trend is possible without parsing
# the human output. Sizes travel with the timings: a duration with no input
# size attached cannot be extrapolated to anyone else's dataset.
if [ -n "${RTO_RECORD:-}" ]; then
  set_bytes="$(du -sb "${FROM}" 2>/dev/null | cut -f1)"
  {
    printf '{"at":"%s","set":"%s","set_bytes":%s' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "${FROM}")" "${set_bytes:-0}"
    for entry in "${PHASE_LOG[@]}"; do
      printf ',"%s_ms":%s' "${entry%%:*}" "${entry##*:}"
    done
    printf ',"restore_total_ms":%s}\n' "${TOTAL_MS}"
  } >> "${RTO_RECORD}"
  ok "timings appended to ${RTO_RECORD}"
fi

echo
green "Restore complete."
echo
warn "Solr was not restored — it is derived state. Search-backed reads will be"
warn "incomplete until Alfresco reindexes. Verify with compliance_flow's"
warn "smoke-flows.mjs before declaring the system recovered."
