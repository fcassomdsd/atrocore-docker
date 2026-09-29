#!/usr/bin/env bash
#
# backup-platform.sh — back up every dataset the platform cannot rebuild.
#
# Before this, exactly one of four was covered: backup-db.sh dumps the AtroCore
# database and nothing touched Alfresco's database, compliance_web's database,
# or the Alfresco content store. A database backup without its matching content
# store is not a restorable system.
#
#   ./scripts/backup-platform.sh [--dest DIR] [--retention-days N] [--yes]
#
#   --dest            where backups go (default: $BACKUP_DIR, else ../backups).
#                     In production point this at a volume SEPARATE from the
#                     data it protects -- a backup on the same disk as the
#                     database protects against exactly one failure mode.
#   --retention-days  prune sets older than this (default 30, 0 = keep all).
#   --yes             skip the confirmation prompt.
#
# WHAT IS AND IS NOT BACKED UP
#   Backed up:  AtroCore DB, Alfresco DB, compliance_web DB, Alfresco content
#               store.
#   Also captured: a physical base backup per database (pg_basebackup), which
#   is what makes the WAL archive usable. A pg_dump CANNOT be combined with
#   WAL -- point-in-time recovery replays WAL onto a *physical* base, so
#   without basebackups the archive is inert and RPO stays bounded by the
#   backup interval rather than by archive_timeout.
#
#   The two serve different jobs and both are kept:
#     - the logical dumps are the restore path (simple, version-portable,
#       exercised by restore-verify-ci.sh)
#     - basebackup + WAL is the RPO path (recover to a point in time)
#
#   Not backed up, on purpose:
#     - Solr indexes. Derived state; rebuilt by reindexing. Backing them up
#       would store a stale copy of something reconstructible.
#     - AtroCore's web-data/. Reinstalled at container bootstrap.
#     - .env files and secrets. They belong in a secret manager, not in a
#       backup set that gets copied around (see P3.1).
#
# ORDERING IS A CORRECTNESS PROPERTY, NOT A PREFERENCE
#   Databases are dumped FIRST, the content store SECOND. Alfresco's database
#   holds references to content-store files. If the content were captured
#   first, any document created between the two steps would be referenced by
#   the later database dump and absent from the backup -- a dangling reference
#   that surfaces as a broken document on restore. In this order the worst case
#   is a content file with no database row: an orphan, invisible and harmless.
#
#   This is not a substitute for quiescing the stack. For a consistent
#   point-in-time set, stop Alfresco first. The ordering makes an online
#   backup degrade safely; it does not make it atomic.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
DEST="${BACKUP_DIR:-${WORKSPACE}/backups}"
RETENTION_DAYS=30
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --dest=*) DEST="${1#*=}"; shift ;;
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    --retention-days=*) RETENTION_DAYS="${1#*=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Read a variable out of a .env without sourcing it. `set -a; . .env` exports
# everything in the file, including COMPOSE_PROJECT_NAME and friends, which
# then silently redirect every later `docker compose` call in this script --
# the exact failure that cost a debugging cycle in demo-quickstart.sh.
env_var() { # env_var <file> <name>
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}

compose_running() { # compose_running <dir> <service>
  [ -d "$1" ] || return 1
  ( cd "$1" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null ) | grep -qx "$2"
}

dump_db() { # dump_db <label> <dir> <service> <user> <db> <outfile>
  local label="$1" dir="$2" svc="$3" user="$4" db="$5" out="$6"
  if ! compose_running "${dir}" "${svc}"; then
    warn "${label}: service '${svc}' is not running — skipped"
    SKIPPED=$((SKIPPED + 1)); return
  fi
  if ! ( cd "${dir}" && docker compose exec -T "${svc}" pg_dump -U "${user}" -d "${db}" -Fc ) > "${out}" 2>/dev/null; then
    die "${label}: pg_dump failed"
  fi
  [ -s "${out}" ] || die "${label}: dump is empty"
  ok "${label}: $(du -h "${out}" | cut -f1) -> $(basename "${out}")"
}

bold "backup-platform"
echo "destination: ${DEST}"
echo "retention:   ${RETENTION_DAYS} day(s)"
if [ "${ASSUME_YES}" -ne 1 ]; then
  printf 'Proceed? [y/N] '; read -r a; case "$a" in y|Y) ;; *) echo "aborted"; exit 0 ;; esac
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${DEST}/${TIMESTAMP}"
mkdir -p "${SET_DIR}" || die "cannot create ${SET_DIR}"
SKIPPED=0

# --- databases first (see the ordering note in the header) -----------------
step "1. Databases"

ATRO_ENV="${REPO_DIR}/.env"
dump_db "AtroCore DB" "${REPO_DIR}" db \
  "$(env_var "${ATRO_ENV}" POSTGRES_PIM_USER)" \
  "$(env_var "${ATRO_ENV}" POSTGRES_PIM_DB)" \
  "${SET_DIR}/atrocore.dump"

dump_db "Alfresco DB" "${WORKSPACE}/compliance_cmis" postgres alfresco alfresco \
  "${SET_DIR}/alfresco.dump"

WEB_ENV="${WORKSPACE}/compliance_web/.env"
dump_db "compliance_web DB" "${WORKSPACE}/compliance_web" db \
  "$(env_var "${WEB_ENV}" POSTGRES_USER)" \
  "$(env_var "${WEB_ENV}" POSTGRES_DB)" \
  "${SET_DIR}/compliance_web.dump"

# --- physical base backups, for point-in-time recovery ---------------------
step "1b. Base backups (for WAL replay)"
basebackup() { # basebackup <label> <dir> <service> <user> <outdir>
  local label="$1" dir="$2" svc="$3" user="$4" out="$5"
  if ! compose_running "${dir}" "${svc}"; then
    warn "${label}: not running — skipped"; SKIPPED=$((SKIPPED + 1)); return
  fi
  # -Xf, not -Xs: streaming WAL cannot be combined with a tar written to
  # stdout ("cannot stream write-ahead logs in tar mode to stdout"), and
  # writing to a path inside the container then copying it out would need
  # space the container may not have. -Xf fetches the required WAL at the end
  # instead, which is safe here because archive_mode is on, so any segment it
  # needs is also in the archive.
  #
  # These are large -- a mostly-empty Alfresco database produces ~160 MB
  # against a 376 KB logical dump -- because a base backup is a physical copy
  # including free space. That is the price of point-in-time recovery; the
  # logical dumps remain the cheap, fast restore path.
  local err
  err="$( ( cd "${dir}" && docker compose exec -T "${svc}" \
        pg_basebackup -U "${user}" -D - -Ft -Xf ) > "${out}" 2>&1 )"
  if [ -s "${out}" ]; then
    ok "${label}: $(du -h "${out}" | cut -f1) -> $(basename "${out}")"
  else
    # Counted as a skipped dataset, not merely warned about. A failure here
    # used to leave exit status 0 and the closing line "Backup set complete",
    # so a set with no PITR base announced itself as whole -- which is how
    # AtroCore went without one indefinitely (see the role note below). The
    # logical dump is still present and still restores; what is lost is the
    # ability to recover to a point in time, and the set must say so.
    warn "${label}: base backup failed — PITR will NOT be possible from this set"
    [ -n "${err}" ] && printf '         %s\n' "${err}" | head -3
    rm -f "${out}"
    SKIPPED=$((SKIPPED + 1))
  fi
}
# postgres, not POSTGRES_PIM_USER. pg_basebackup opens a replication
# connection, which needs SUPERUSER or REPLICATION; this image's init scripts
# create the application role (`usuario`) with neither, while `postgres`
# remains the superuser. Passing the application role failed every night with
# "must be superuser or replication role to start walsender" -- and because
# that failure only warned, every set ever taken was missing
# atrocore.basebackup.tar and PITR for AtroCore was impossible. Found by the
# first run of the PITR drill. The other two databases connect as their
# image's POSTGRES_USER, which is a superuser, so they were unaffected.
basebackup "AtroCore base"      "${REPO_DIR}" db postgres "${SET_DIR}/atrocore.basebackup.tar"
basebackup "Alfresco base"      "${WORKSPACE}/compliance_cmis" postgres alfresco              "${SET_DIR}/alfresco.basebackup.tar"
basebackup "compliance_web base" "${WORKSPACE}/compliance_web" db "$(env_var "${WEB_ENV}" POSTGRES_USER)" "${SET_DIR}/compliance_web.basebackup.tar"

# --- content store second --------------------------------------------------
step "2. Alfresco content store"
ALF_DATA="${WORKSPACE}/compliance_cmis/data/alf_data"
if [ -d "${ALF_DATA}" ]; then
  # Tarred from inside a container: the content store is written by Alfresco's
  # own uid and is not readable by the invoking user. Same reason the three
  # bootstrap scripts exist.
  if docker run --rm -v "${ALF_DATA}:/src:ro" -v "${SET_DIR}:/out" alpine:latest \
       tar czf /out/alf_data.tar.gz -C /src . 2>/dev/null; then
    ok "content store: $(du -h "${SET_DIR}/alf_data.tar.gz" | cut -f1) -> alf_data.tar.gz"
  else
    die "content store: tar failed"
  fi
else
  warn "content store: ${ALF_DATA} not found — skipped"
  SKIPPED=$((SKIPPED + 1))
fi

# --- manifest --------------------------------------------------------------
step "3. Manifest"
{
  echo "# compliance-platform backup set"
  echo "created_utc: ${TIMESTAMP}"
  echo "host: $(hostname)"
  echo "wal_archives:"
  for spec in "atrocore:${REPO_DIR}/wal-archive" \
              "alfresco:${WORKSPACE}/compliance_cmis/data/wal-archive" \
              "compliance_web:${WORKSPACE}/compliance_web/data/wal-archive"; do
    name="${spec%%:*}"; path="${spec#*:}"
    if [ -d "${path}" ]; then
      echo "  - name: ${name}"
      echo "    path: ${path}"
      echo "    segments: $(find "${path}" -type f 2>/dev/null | wc -l | tr -d ' ')"
    fi
  done
  echo "# PITR = the newest *.basebackup.tar in this set, plus WAL from the"
  echo "# archive paths above. The archive is a continuous store and is NOT"
  echo "# copied into every set; back it up separately or ship it offsite."
  # Stated per dataset rather than left to be inferred from the file list. A
  # missing base backup is the difference between "recoverable to a point in
  # time" and "recoverable to last night", and reading that off the absence of
  # a filename is exactly how it went unnoticed.
  echo "pitr:"
  for name in atrocore alfresco compliance_web; do
    if [ -s "${SET_DIR}/${name}.basebackup.tar" ]; then
      echo "  - name: ${name}"
      echo "    base: ${name}.basebackup.tar"
      echo "    recoverable_to_point_in_time: yes"
    else
      echo "  - name: ${name}"
      echo "    base: none"
      echo "    recoverable_to_point_in_time: no"
    fi
  done
  echo "files:"
  for f in "${SET_DIR}"/*; do
    [ "$(basename "$f")" = "MANIFEST" ] && continue
    echo "  - name: $(basename "$f")"
    echo "    bytes: $(stat -c %s "$f")"
    echo "    sha256: $(sha256sum "$f" | cut -d' ' -f1)"
  done
} > "${SET_DIR}/MANIFEST"
ok "MANIFEST written ($(grep -c 'sha256:' "${SET_DIR}/MANIFEST") file(s) checksummed)"

# --- retention -------------------------------------------------------------
if [ "${RETENTION_DAYS}" -gt 0 ]; then
  step "4. Retention"
  pruned=0
  while IFS= read -r old; do
    rm -rf "${old}" && pruned=$((pruned + 1))
  done < <(find "${DEST}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" 2>/dev/null)
  ok "pruned ${pruned} set(s) older than ${RETENTION_DAYS} days"

  # WAL retention follows set retention, and runs AFTER the sets are pruned so
  # the anchor reflects what is actually still kept rather than what was kept
  # a minute ago.
  #
  # Without this the archive grows forever: archive_timeout=300 writes a 16MB
  # segment at least every five minutes per database, and measured on this
  # platform that came to ~3 GB/day across the three. The volume filling is
  # not a tidiness problem -- a full volume makes archive_command fail, which
  # makes PostgreSQL retain WAL in pg_wal, which stops the database.
  #
  # It cuts at the oldest base backup still present under ${DEST}, so it can
  # never remove a segment one of the retained sets needs. A failure here does
  # not fail the backup: the only honest reason it can fail is a dataset with
  # no base backup, and that already failed the run above as a skipped dataset.
  if [ -x "${REPO_DIR}/scripts/prune-wal-archive.sh" ]; then
    if ! "${REPO_DIR}/scripts/prune-wal-archive.sh" --dest "${DEST}" --yes --quiet; then
      warn "WAL pruning did not complete — the archive will keep growing until it does"
    fi
  fi
fi

echo
if [ "${SKIPPED}" -gt 0 ]; then
  warn "${SKIPPED} dataset(s) skipped — this set is INCOMPLETE and will not restore a whole system"
  echo "${SET_DIR}"
  exit 1
fi
green "Backup set complete: ${SET_DIR}"
echo
echo "Restore it with:  ./scripts/restore-platform.sh --from ${SET_DIR}"
