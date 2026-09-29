#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Ship archived WAL offsite, asynchronously.
#
#   scripts/ship-wal-archive.sh [--archive <dir> --label <name>]
#                               [--prune-local <days>] [--dry-run]
#
# WHY THIS IS A SEPARATE PROCESS AND NOT archive_command
# ------------------------------------------------------
# It is tempting to point archive_command straight at the offsite
# destination. Doing so would be a serious mistake, and it is worth stating
# why in the place someone would go to change it.
#
# archive_command runs INSIDE PostgreSQL, synchronously, once per 16MB
# segment, and PostgreSQL will not recycle a segment until it returns
# success. Put a network there and two things follow. Latency becomes a
# database problem: a slow destination throttles WAL recycling and
# eventually writes. And a failure becomes a disk problem: PostgreSQL
# retains every unarchived segment until archiving succeeds, so an
# unreachable offsite destination fills the data volume and stops the
# database. That is the hazard already documented for local archiving --
# pointing it at a network multiplies the ways it fires.
#
# So archiving stays local, fast and certain, and this ships what has
# accumulated. If the destination is unreachable, segments queue on disk and
# the database does not care.
#
# WHAT IT SHIPS
# -------------
# A batch: every locally archived segment not yet recorded as shipped,
# packaged as a directory with a MANIFEST, and pushed with the same driver
# and the same machinery as a backup set -- so the MANIFEST-last rule, the
# checksum verification and the capability handling all apply unchanged.
#
# Configure the destination exactly as for backup-offsite.sh. Point it at a
# DIFFERENT path or prefix from your backup sets: WAL is small and frequent,
# sets are large and rare, and they usually want different retention.
#
#   BACKUP_DESTINATION=s3
#   BACKUP_S3_BUCKET=oversight-backups
#   BACKUP_S3_PREFIX=wal            # sets live under a different prefix
#
# ON --prune-local
# ----------------
# Off by default, and deliberately so. Deleting a WAL segment that a base
# backup still needs destroys point-in-time recovery from that base, and
# nothing will tell you until a restore. A segment is only ever removed when
# all three hold: it has been confirmed shipped, it is older than the given
# age, and it is older than the oldest base backup still retained locally.
#
# That last condition used to be a sentence in this comment telling the
# operator to pass an age at least as large as their set retention. Nothing
# checked it, and an age is the wrong kind of rule anyway -- see
# wal-anchor.lib.sh. It is now enforced against the actual backups on disk,
# and a stream with no base backup to anchor to is not pruned at all.
#
# For pruning that is not tied to shipping, use prune-wal-archive.sh; it
# applies the same anchor and is what the nightly backup calls.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
# shellcheck source=scripts/wal-anchor.lib.sh
. "${REPO_DIR}/scripts/wal-anchor.lib.sh"
SET_DIR_ROOT="${BACKUP_DIR:-${WORKSPACE}/backups}"
STATE_DIR="${WAL_SHIP_STATE_DIR:-${WORKSPACE}/backups/.wal-ship-state}"

ARCHIVE=""; LABEL=""; PRUNE_DAYS=""; DRY_RUN=0
BATCH_MAX="${WAL_SHIP_BATCH_MAX:-512}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1" >&2; }
step()  { printf '\n=== %s\n' "$1"; }
ok()    { printf '    ok   %s\n' "$1"; }
info()  { printf '    ..   %s\n' "$1"; }
warn()  { printf '    !!   %s\n' "$1"; }
die()   { red "    FAIL $1"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --archive)      ARCHIVE="${2:?--archive needs a directory}"; shift 2 ;;
    --label)        LABEL="${2:?--label needs a name}"; shift 2 ;;
    --prune-local)  PRUNE_DAYS="${2:?--prune-local needs a number of days}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '4,61p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "${BACKUP_DESTINATION:-}" ] || die "BACKUP_DESTINATION is not set — see backup-destinations/README.md"

# Only one shipper at a time. Two concurrent runs would both read the same
# unshipped segments and race on the state file.
LOCK="${STATE_DIR}/.lock"
mkdir -p "${STATE_DIR}"
exec 9>"${LOCK}"
flock -n 9 || die "another shipper is already running (${LOCK})"

# The three archives this platform creates. Each is shipped as its own
# stream with its own state, because they are three separate databases and a
# segment name only identifies a file within one of them.
declare -a ARCHIVES LABELS
if [ -n "${ARCHIVE}" ]; then
  [ -n "${LABEL}" ] || die "--archive also needs --label"
  ARCHIVES=("${ARCHIVE}"); LABELS=("${LABEL}")
else
  ARCHIVES=(
    "${REPO_DIR}/wal-archive"
    "${WORKSPACE}/compliance_cmis/data/wal-archive"
    "${WORKSPACE}/compliance_web/data/wal-archive"
  )
  LABELS=(atrocore alfresco compliance_web)
fi

TOTAL_SHIPPED=0
TOTAL_PRUNED=0
FAILURES=0

for i in "${!ARCHIVES[@]}"; do
  ARCH="${ARCHIVES[$i]}"
  NAME="${LABELS[$i]}"
  STATE="${STATE_DIR}/${NAME}.shipped"

  step "${NAME}: ${ARCH}"
  if [ ! -d "${ARCH}" ]; then
    warn "no archive directory — skipped"
    continue
  fi

  # A segment written by the database's own uid is often not readable by the
  # invoking user: compliance_cmis's archive is owned by 999. Read through a
  # container in that case, the same way backup-platform.sh tars the Alfresco
  # content store. Detected rather than assumed, so an unreadable archive is
  # never silently shipped as "nothing to do" -- which is exactly how a
  # backup system ends up with no backups and a green log.
  READ_VIA_DOCKER=0
  # `|| true` is load-bearing under `set -e`: an assignment takes the exit
  # status of its command substitution, so a failing find here killed the
  # whole script silently -- before the listing guard below could report it.
  # Found by stubbing find to fail, which is what BusyBox effectively did.
  first="$(find "${ARCH}" -maxdepth 1 -type f 2>/dev/null | head -1 || true)"
  if [ -n "${first}" ] && ! head -c 1 "${first}" >/dev/null 2>&1; then
    command -v docker >/dev/null 2>&1 \
      || die "${NAME}: segments are not readable by $(id -un) and docker is unavailable.
         Either run this as a user that can read ${ARCH}, or make it group-readable."
    READ_VIA_DOCKER=1
    info "segments are owned by another uid; reading through a container"
  fi

  # `find -printf` is GNU-only and BusyBox does not have it. The container
  # here is Alpine, so the first version of this listed nothing at all and
  # reported "nothing new to ship" against an archive holding 252 segments
  # -- the silent success this script's own comments warn about, produced by
  # the script itself. Strip the directory with sed instead; that works
  # everywhere.
  # Checked before anything reads the listing, so a broken listing tool is
  # reported rather than silently becoming "nothing to ship".
  list_segments() {
    if [ "${READ_VIA_DOCKER}" -eq 1 ]; then
      docker run --rm -v "${ARCH}:/wal:ro" alpine:latest \
        sh -c 'find /wal -maxdepth 1 -type f 2>/dev/null' | sed 's#.*/##' | sort
    else
      find "${ARCH}" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##' | sort
    fi
  }

  # "The listing is empty" and "the listing failed" look identical to
  # everything downstream, and only one of them is safe. Cross-check against
  # a count taken a different way before believing there is nothing to do.
  assert_listing_sane() {
    local listed raw
    listed="$(list_segments | grep -c . || true)"
    raw="$(ls -1A "${ARCH}" 2>/dev/null | grep -c . || true)"
    if [ "${listed}" -eq 0 ] && [ "${raw}" -gt 0 ]; then
      die "${NAME}: the archive holds ${raw} entrie(s) but the listing returned none.
         Shipping nothing would look like success. Check that the segments are
         readable and that the container listing works."
    fi
  }

  assert_listing_sane
  touch "${STATE}"
  # Segments not yet recorded as shipped. comm needs both sides sorted.
  mapfile -t PENDING < <(comm -23 <(list_segments) <(sort -u "${STATE}") | head -n "${BATCH_MAX}")

  if [ "${#PENDING[@]}" -eq 0 ]; then
    ok "nothing new to ship"
  else
    info "${#PENDING[@]} segment(s) to ship"
    if [ "${DRY_RUN}" -eq 1 ]; then
      ok "dry run — not shipping"
    else
      BATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)"
      STAGE="$(mktemp -d)"
      BATCH="${STAGE}/${BATCH_ID}"
      mkdir -p "${BATCH}"

      copy_ok=1
      if [ "${READ_VIA_DOCKER}" -eq 1 ]; then
        printf '%s\n' "${PENDING[@]}" > "${STAGE}/wanted"
        # chown/chmod after copying, and this is not cosmetic. PostgreSQL
        # writes WAL mode 0600; the container runs as root, cp preserves the
        # mode, and the staged copies come out root-owned and unreadable by
        # the user who then has to checksum and push them. The first version
        # got as far as writing a MANIFEST and then failed its own integrity
        # check with every segment "missing".
        docker run --rm -v "${ARCH}:/wal:ro" -v "${STAGE}:/stage" alpine:latest \
          sh -c 'cd /wal && while IFS= read -r f; do [ -f "$f" ] && cp -f "$f" "/stage/'"${BATCH_ID}"'/"; done < /stage/wanted;
                 chown -R '"$(id -u):$(id -g)"' "/stage/'"${BATCH_ID}"'" && chmod -R u+rw "/stage/'"${BATCH_ID}"'"' \
          || copy_ok=0
      else
        for f in "${PENDING[@]}"; do cp -f "${ARCH}/${f}" "${BATCH}/" || copy_ok=0; done
      fi

      if [ "${copy_ok}" -ne 1 ]; then
        rm -rf "${STAGE}"; red "    FAIL ${NAME}: could not stage segments"; FAILURES=$((FAILURES+1)); continue
      fi

      # A MANIFEST in the same shape backup-platform.sh writes, so the
      # existing push/verify machinery treats a WAL batch exactly like a
      # backup set -- including verifying it before it is sent.
      {
        echo "created_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "kind: wal-batch"
        echo "stream: ${NAME}"
        echo "files:"
        for f in "${PENDING[@]}"; do
          [ -f "${BATCH}/${f}" ] || continue
          echo "  - name: ${f}"
          echo "    sha256: $(sha256sum "${BATCH}/${f}" | cut -d' ' -f1)"
        done
      } > "${BATCH}/MANIFEST"

      if BACKUP_DIR="${STAGE}" "${REPO_DIR}/scripts/backup-offsite.sh" push --set "${BATCH}" >/dev/null; then
        # Only record as shipped after the push returned success. The
        # opposite order loses segments permanently on a failed transfer:
        # they would be marked done, never retried, and missing from the
        # archive after the next local prune.
        for f in "${PENDING[@]}"; do [ -f "${BATCH}/${f}" ] && echo "${f}"; done >> "${STATE}"
        sort -u -o "${STATE}" "${STATE}"
        ok "shipped ${#PENDING[@]} segment(s) as ${BATCH_ID}"
        TOTAL_SHIPPED=$((TOTAL_SHIPPED + ${#PENDING[@]}))
      else
        red "    FAIL ${NAME}: push failed — segments stay queued and will be retried"
        FAILURES=$((FAILURES+1))
      fi
      rm -rf "${STAGE}"
    fi
  fi

  # --- optional local pruning ---------------------------------------------
  if [ -n "${PRUNE_DAYS}" ] && [ "${DRY_RUN}" -eq 0 ]; then
    pruned=0
    cutoff=$(( $(date -u +%s) - (PRUNE_DAYS * 86400) ))
    # The hard floor, below which age does not get a vote: the START WAL of
    # the oldest base backup still on disk. Anything from there on is what a
    # retained set replays onto.
    anchor="$(wal_anchor_for "${SET_DIR_ROOT}" "${NAME}" || true)"
    if [ -z "${anchor}" ]; then
      warn "no base backup under ${SET_DIR_ROOT} to anchor pruning to — not pruning ${NAME}"
      continue
    fi
    info "prune floor ${anchor} (oldest retained base backup's START WAL)"
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      # Shipped is necessary but not sufficient, and neither is age. All three
      # conditions are checked here; the anchor is the one that decides
      # whether a restore still works.
      grep -qxF "${f}" "${STATE}" 2>/dev/null || continue
      # Compared on the segment part, the last 16 characters, which is what
      # pg_archivecleanup compares: the leading 8 are the timeline.
      case "${f}" in
        *.history) continue ;;
        [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]*) ;;
        *) continue ;;
      esac
      [[ "${f:8:16}" < "${anchor:8:16}" ]] || continue
      if [ "${READ_VIA_DOCKER}" -eq 1 ]; then
        mtime="$(docker run --rm -v "${ARCH}:/wal:ro" alpine:latest stat -c %Y "/wal/${f}" 2>/dev/null || echo 0)"
      else
        mtime="$(stat -c %Y "${ARCH}/${f}" 2>/dev/null || echo 0)"
      fi
      [ "${mtime}" -gt 0 ] && [ "${mtime}" -lt "${cutoff}" ] || continue
      if [ "${READ_VIA_DOCKER}" -eq 1 ]; then
        docker run --rm -v "${ARCH}:/wal" alpine:latest rm -f "/wal/${f}" >/dev/null 2>&1 && pruned=$((pruned+1))
      else
        rm -f "${ARCH}/${f}" && pruned=$((pruned+1))
      fi
    done < <(list_segments)
    [ "${pruned}" -gt 0 ] && ok "pruned ${pruned} shipped segment(s) older than ${PRUNE_DAYS}d" || info "nothing local to prune"
    TOTAL_PRUNED=$((TOTAL_PRUNED + pruned))
  fi
done

echo
if [ "${FAILURES}" -gt 0 ]; then
  red "${FAILURES} stream(s) failed to ship. Segments remain queued locally and will be retried."
  red "If this persists, the local archive grows until the volume fills — see the WAL alerts in observability/."
  exit 1
fi
green "WAL shipped: ${TOTAL_SHIPPED} segment(s)$( [ -n "${PRUNE_DAYS}" ] && printf ', %s pruned locally' "${TOTAL_PRUNED}" )."
