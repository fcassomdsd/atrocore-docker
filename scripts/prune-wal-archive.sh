#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Prune archived WAL that no retained base backup can replay onto.
#
#   scripts/prune-wal-archive.sh [--dataset <name>] [--dest <dir>]
#                                [--archive <dir>] [--anchor <walfile>]
#                                [--yes] [--quiet]
#
#   --dataset  atrocore | alfresco | compliance_web (default: all three).
#   --dest     backup sets directory, where the anchor is read from
#              (default: $BACKUP_DIR, else ../backups).
#   --archive  override the archive directory; requires --dataset.
#   --anchor   prune against this WAL segment instead of looking one up.
#              For the case where the sets live offsite and none is local.
#   --local    run pg_archivecleanup from PATH instead of in a container
#              (also WAL_PRUNE_LOCAL=1). Needs an archive you can read.
#   --yes      actually delete. WITHOUT IT THIS IS A DRY RUN.
#   --quiet    only print what changed; for the nightly caller.
#
# WHAT THIS IS FOR
# ----------------
# archive_mode=on with archive_timeout=300 buys a five-minute RPO by writing
# a 16MB segment at least every five minutes, per database, forever. Nothing
# reclaims them. Measured on this platform on 2026-09-29, ~2.5 days after
# archiving was switched on: 5.5 GB / 350 segments for Alfresco, 1.2 GB / 85
# for AtroCore, 529 MB / 37 for compliance_web -- about 3 GB/day, on a disk
# that had reached 99%.
#
# That is the same failure the archive is supposed to protect against. When
# the volume fills, archive_command starts failing, PostgreSQL retains WAL in
# pg_wal rather than discarding it, and the database stops. An archive with
# no retention policy is a scheduled outage.
#
# THE BOUNDARY IS A BASE BACKUP, NOT A DATE
# -----------------------------------------
# See wal-anchor.lib.sh. In short: the oldest segment worth keeping is the one
# the OLDEST RETAINED base backup started in, which is recorded inside that
# backup's own backup_label. Before it, nothing you hold can replay. After it,
# everything is load-bearing.
#
# IT REFUSES RATHER THAN GUESSES
# ------------------------------
# With no base backup to anchor to, this deletes nothing and exits non-zero.
# A "retention policy" that cannot find the boundary and removes files anyway
# is not retention. That case is a real one -- a dataset whose base backup
# failed has no anchor, which is exactly the state AtroCore was in for days --
# and the right answer is to fix the backup, not to free the disk.
#
# THE ANCHOR IS LOCAL. IF YOUR OLDER SETS ARE ONLY OFFSITE, SAY SO.
# -----------------------------------------------------------------
# It looks under --dest, which is the local sets directory. A base backup
# that exists only at the offsite destination is invisible here, and the WAL
# it would replay onto will be pruned as unreachable. That is the one way
# this tool can destroy recovery from a backup you still hold.
#
# If you keep older sets offsite and expect to restore them, pass --anchor
# with the START WAL of the oldest one -- it is in that backup's backup_label
# -- or keep the archive shipped offsite with it (ship-wal-archive.sh) and
# prune only what has been confirmed shipped.
#
# The first run after adopting this will usually remove a lot, because the
# WAL written before your oldest base backup cannot be replayed by anything
# you hold. That is dead weight, not recovery capability. Look at the dry
# run before believing it.
#
# HOW pg_archivecleanup IS RUN, AND THE MOUNT IT DEPENDS ON
# ---------------------------------------------------------
# Normally in a container, because a real archive is written by the database's
# uid at mode 0700 and the invoking user cannot read it. That makes the tool
# depend on a bind mount resolving to the directory the caller meant -- and
# where the Docker daemon is not on the same filesystem as the caller, as
# under docker-in-docker, it silently does not. Docker creates an empty
# directory instead, pg_archivecleanup finds nothing to do, and the run
# reports "would remove 0 of 0 segments" and exits 0. That is the exact shape
# of failure this tool exists to prevent: an archive growing without bound
# while something reports success every night. Found by this repository's own
# CI, where the conformance test's fixtures live on the job container and the
# mount reached the dind daemon.
#
# So when the archive IS readable from here, the count seen through the mount
# is checked against the count seen directly, and a disagreement is fatal. When
# it is not readable -- the normal case on a real host -- there is nothing to
# compare against and the container's view is trusted.
#
# WAL_PRUNE_LOCAL=1 runs pg_archivecleanup from PATH instead, for hosts that
# have it installed and archives the caller can read.
#
# pg_archivecleanup does the comparison. It is the tool PostgreSQL ships for
# this, it understands .backup and .partial suffixes and leaves .history files
# alone, and reimplementing its ordering in shell to save a container would be
# a poor trade.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
# shellcheck source=scripts/wal-anchor.lib.sh
. "${SCRIPT_DIR}/wal-anchor.lib.sh"

DEST="${BACKUP_DIR:-${WORKSPACE}/backups}"
DATASET=""; ARCHIVE=""; ANCHOR=""; APPLY=0; QUIET=0
# Any PostgreSQL image will do: pg_archivecleanup compares segment FILENAMES
# and never opens the cluster, so unlike restore-pitr.sh this does not have to
# match the major version that wrote the backup. Fixed rather than resolved
# from compose so the nightly job keeps working when a sibling repo is not
# checked out.
PRUNE_IMAGE="${WAL_PRUNE_IMAGE:-postgres:16-alpine}"
# Run pg_archivecleanup directly rather than through a container. Off by
# default: the container path is the one a real archive needs.
LOCAL="${WAL_PRUNE_LOCAL:-0}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; BLD=""; RST=""; }
step() { [ "${QUIET}" -eq 1 ] || printf '\n%s=== %s%s\n' "${BLD}" "$*" "${RST}"; }
ok()   { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; }
info() { [ "${QUIET}" -eq 1 ] || printf '    ..   %s\n' "$*"; }
warn() { printf '    %s!!%s   %s\n' "${YEL}" "${RST}" "$*"; }
die()  { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dataset) DATASET="${2:?--dataset needs a name}"; shift 2 ;;
    --dest)    DEST="${2:?--dest needs a directory}"; shift 2 ;;
    --archive) ARCHIVE="${2:?--archive needs a directory}"; shift 2 ;;
    --anchor)  ANCHOR="${2:?--anchor needs a WAL segment name}"; shift 2 ;;
    --local)   LOCAL=1; shift ;;
    --yes|-y)  APPLY=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) sed -n '5,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

declare -a NAMES ARCHIVES
if [ -n "${ARCHIVE}" ]; then
  [ -n "${DATASET}" ] || die "--archive also needs --dataset, so the anchor can be found"
  NAMES=("${DATASET}"); ARCHIVES=("${ARCHIVE}")
else
  NAMES=(atrocore alfresco compliance_web)
  ARCHIVES=(
    "${REPO_DIR}/wal-archive"
    "${WORKSPACE}/compliance_cmis/data/wal-archive"
    "${WORKSPACE}/compliance_web/data/wal-archive"
  )
  if [ -n "${DATASET}" ]; then
    idx=-1
    for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "${DATASET}" ] && idx=$i; done
    [ "${idx}" -ge 0 ] || die "unknown dataset: ${DATASET} (expected atrocore | alfresco | compliance_web)"
    NAMES=("${DATASET}"); ARCHIVES=("${ARCHIVES[$idx]}")
  fi
fi

[ "${APPLY}" -eq 1 ] || info "DRY RUN — nothing will be deleted. Re-run with --yes to apply."
if [ "${LOCAL}" -eq 1 ]; then
  command -v pg_archivecleanup >/dev/null 2>&1 || die "--local needs pg_archivecleanup on PATH"
  info "running pg_archivecleanup directly (--local)"
else
  docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"
fi

# count_segments <dir> -- through the same lens the cleanup will use
count_segments() {
  if [ "${LOCAL}" -eq 1 ]; then
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    docker run --rm -v "$1:/wal:ro" alpine:latest \
      sh -c 'find /wal -type f 2>/dev/null | wc -l' | tr -d ' '
  fi
}

TOTAL_REMOVED=0
FAILURES=0

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; arch="${ARCHIVES[$i]}"
  step "${name}"

  if [ ! -d "${arch}" ]; then
    info "${arch} does not exist — nothing archived for this dataset"
    continue
  fi

  # Counted in a container. These directories are written by the database's
  # uid and are not always readable by the invoking user, and an archive that
  # cannot be listed must never be treated as an empty one -- the same trap
  # restore-pitr.sh guards against.
  before="$(count_segments "${arch}")"
  case "${before}" in ''|*[!0-9]*) die "${name}: could not list ${arch}" ;; esac

  # Does the lens agree with the naked eye? Only asked when the naked eye can
  # see: on a real host this directory belongs to the database's uid and the
  # find below returns nothing for want of permission, which is not evidence
  # of anything and is skipped.
  if [ "${LOCAL}" -eq 0 ] && [ -r "${arch}" ]; then
    direct="$(find "${arch}" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${direct}" -gt 0 ] && [ "${before}" -ne "${direct}" ]; then
      die "${name}: the container sees ${before} file(s) in ${arch} but this host sees ${direct} — the bind mount is not reaching the directory you meant (docker-in-docker, a remote daemon, or a path that does not exist on the daemon's filesystem). Refusing: pruning what a mount cannot see reports success and removes nothing."
    fi
  fi

  anchor="${ANCHOR}"
  if [ -z "${anchor}" ]; then
    anchor="$(wal_anchor_for "${DEST}" "${name}")"
  fi
  if [ -z "${anchor}" ]; then
    warn "${name}: no base backup found under ${DEST} — refusing to prune ${before} segment(s)"
    warn "        without one there is nothing to replay onto, so every segment here is either"
    warn "        load-bearing or already useless, and this cannot tell which. Fix the backup."
    FAILURES=$((FAILURES + 1))
    continue
  fi
  info "anchor ${anchor} (oldest retained base backup's START WAL)"

  # -n is pg_archivecleanup's own dry run, so the dry-run path and the real
  # path make the same decision with the same code rather than one predicting
  # the other.
  if [ "${LOCAL}" -eq 1 ]; then
    if [ "${APPLY}" -eq 1 ]; then out="$(pg_archivecleanup -d "${arch}" "${anchor}" 2>&1)"; rc=$?
    else                          out="$(pg_archivecleanup -n "${arch}" "${anchor}" 2>&1)"; rc=$?; fi
  elif [ "${APPLY}" -eq 1 ]; then
    out="$(docker run --rm -u 0 -v "${arch}:/wal" "${PRUNE_IMAGE}" \
      pg_archivecleanup -d /wal "${anchor}" 2>&1)"
    rc=$?
  else
    out="$(docker run --rm -u 0 -v "${arch}:/wal:ro" "${PRUNE_IMAGE}" \
      pg_archivecleanup -n /wal "${anchor}" 2>&1)"
    rc=$?
  fi
  if [ ${rc} -ne 0 ]; then
    printf '         %s\n' "${out}" | head -5
    warn "${name}: pg_archivecleanup failed"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  after="$(count_segments "${arch}")"
  case "${after}" in ''|*[!0-9]*) die "${name}: could not re-list ${arch}" ;; esac

  if [ "${APPLY}" -eq 1 ]; then
    removed=$((before - after))
    TOTAL_REMOVED=$((TOTAL_REMOVED + removed))
    if [ "${removed}" -gt 0 ]; then
      ok "${name}: removed ${removed} segment(s), ${after} kept (~$((removed * 16)) MB freed)"
    else
      info "${name}: nothing to remove, ${after} segment(s) kept"
    fi
  else
    # -n lists one path per line on stdout; -d logs "removing file ..." to
    # stderr. Both are captured, so count either form rather than assuming one.
    would="$(printf '%s\n' "${out}" | grep -cE '^/|removing file')"
    [ "${after}" = "${before}" ] || die "${name}: a dry run deleted files — refusing to continue"
    TOTAL_REMOVED=$((TOTAL_REMOVED + would))
    info "${name}: would remove ${would} of ${before} segment(s) (~$((would * 16)) MB)"
  fi
done

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  printf '%s%d dataset(s) could not be pruned — see above.%s\n' "${RED}" "${FAILURES}" "${RST}" >&2
  exit 1
fi
if [ "${APPLY}" -eq 1 ]; then
  printf '%sWAL pruned: %d segment(s) removed.%s\n' "${GRN}" "${TOTAL_REMOVED}" "${RST}"
else
  printf '%sDry run: %d segment(s) would be removed. Re-run with --yes.%s\n' "${YEL}" "${TOTAL_REMOVED}" "${RST}"
fi
