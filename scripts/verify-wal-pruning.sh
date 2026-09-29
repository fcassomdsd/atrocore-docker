#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Conformance test for WAL retention: scripts/wal-anchor.lib.sh and
# scripts/prune-wal-archive.sh.
#
#   scripts/verify-wal-pruning.sh
#
# Runs against synthetic fixtures -- empty files named like WAL segments, and
# tar files containing nothing but a backup_label -- so it needs no database,
# no backup set and no stack, and can be a merge gate.
#
# It needs pg_archivecleanup, and takes it from PATH when one is installed,
# otherwise from a container. That is not only convenience: under
# docker-in-docker a bind mount does NOT reach the caller's filesystem, so
# these fixtures are invisible to the daemon and the container path measures
# an empty directory. CI hit exactly that -- 15 passed, 3 failed, because
# pg_archivecleanup had nothing to clean. prune-wal-archive.sh now refuses
# when the mount and the naked eye disagree, and this picks the mode that can
# actually see the fixtures.
#
# WHAT IT IS ACTUALLY TESTING
# ---------------------------
# Not "does it delete things". Deleting is the easy half and the dangerous
# half. The properties that matter are the ones that decide whether a restore
# works six months from now:
#
#   - the anchor is the OLDEST retained base backup, not the newest;
#   - the anchor segment itself and everything after it survive;
#   - with no base backup, nothing is deleted and the run fails;
#   - a dry run deletes nothing, and predicts exactly what an apply does.
#
# Each of those was mutation-tested against the implementation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/wal-anchor.lib.sh"

RED=$'\033[31m'; GRN=$'\033[32m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; BLD=""; RST=""; }
PASS=0; FAIL=0
ok() { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; PASS=$((PASS + 1)); }
no() { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*"; FAIL=$((FAIL + 1)); }
eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — expected '$2', got '$3'"; fi
}

if command -v pg_archivecleanup >/dev/null 2>&1; then
  export WAL_PRUNE_LOCAL=1
  MODE="pg_archivecleanup from PATH"
else
  docker info >/dev/null 2>&1 || {
    echo "needs either pg_archivecleanup on PATH or a reachable Docker daemon" >&2; exit 1; }
  MODE="pg_archivecleanup in a container"
fi

WORK="$(mktemp -d -t wal-prune-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT INT TERM

# label_tar <path> <wal-file>  — a base backup as far as the anchor cares
label_tar() {
  local out="$1" seg="$2" d
  d="$(mktemp -d -p "${WORK}")"
  printf 'START WAL LOCATION: 0/%s (file %s)\nBACKUP METHOD: streamed\n' "${seg:16:8}" "${seg}" \
    > "${d}/backup_label"
  mkdir -p "$(dirname "${out}")"
  tar cf "${out}" -C "${d}" backup_label
}

seg() { printf '000000010000000000000%03X\n' "$1"; }

printf '%swal retention conformance%s (%s)\n' "${BLD}" "${RST}" "${MODE}"

printf '\n%s=== 1. The anchor%s\n' "${BLD}" "${RST}"

LABEL='START WAL LOCATION: 2/6C000028 (file 00000001000000020000006C)
CHECKPOINT LOCATION: 2/6C001520
BACKUP METHOD: streamed'
eq "reads START WAL out of a real backup_label" \
   "00000001000000020000006C" "$(wal_anchor_from_label "${LABEL}")"

eq "returns nothing for a file that is not a backup_label" \
   "" "$(wal_anchor_from_label 'this is not a backup label')"

# A truncated segment name must not be accepted: a 23-character anchor would
# be handed to pg_archivecleanup, which compares the last 16 characters of it
# and would cut the archive at the wrong place.
eq "rejects a malformed segment name" \
   "" "$(wal_anchor_from_label 'START WAL LOCATION: 2/6C000028 (file 0000000100000002000006C)')"

DEST="${WORK}/backups"
label_tar "${DEST}/20260101T000000Z/atrocore.basebackup.tar" "$(seg 32)"
label_tar "${DEST}/20260102T000000Z/atrocore.basebackup.tar" "$(seg 48)"
label_tar "${DEST}/20260103T000000Z/atrocore.basebackup.tar" "$(seg 64)"
eq "picks the OLDEST of three retained base backups" \
   "$(seg 32)" "$(wal_anchor_for "${DEST}" atrocore)"

eq "a dataset with no base backup has no anchor" \
   "" "$(wal_anchor_for "${DEST}" alfresco)"

# The timeline trap. Sorted as whole filenames, 00000002...0010 ranks above
# 00000001...0040 and would be chosen as the oldest -- cutting the archive 48
# segments too far forward. pg_archivecleanup compares only the segment part,
# so the anchor must be chosen that way too.
DEST_TL="${WORK}/backups-tl"
label_tar "${DEST_TL}/20260101T000000Z/atrocore.basebackup.tar" "000000010000000000000040"
label_tar "${DEST_TL}/20260102T000000Z/atrocore.basebackup.tar" "000000020000000000000010"
eq "orders by the segment part, not the timeline prefix" \
   "000000020000000000000010" "$(wal_anchor_for "${DEST_TL}" atrocore)"

printf '\n%s=== 2. Refusal when there is nothing to anchor to%s\n' "${BLD}" "${RST}"

ARCH="${WORK}/archive"
mkdir -p "${ARCH}"
# 16..40, so the fixture has segments on BOTH sides of the anchor (32).
for i in $(seq 16 40); do : > "${ARCH}/$(seg "${i}")"; done
: > "${ARCH}/00000002.history"
COUNT_BEFORE="$(find "${ARCH}" -type f | wc -l | tr -d ' ')"

OUT="$("${SCRIPT_DIR}/prune-wal-archive.sh" --dataset alfresco --archive "${ARCH}" \
        --dest "${DEST}" --yes 2>&1)"
RC=$?
eq "exits non-zero with no base backup to anchor to" "1" "${RC}"
if printf '%s' "${OUT}" | grep -q 'refusing to prune'; then
  ok "says it is refusing, and why"
else
  no "did not explain the refusal: ${OUT}"
fi
eq "deleted nothing while refusing" \
   "${COUNT_BEFORE}" "$(find "${ARCH}" -type f | wc -l | tr -d ' ')"

printf '\n%s=== 3. Dry run%s\n' "${BLD}" "${RST}"

DRY="$("${SCRIPT_DIR}/prune-wal-archive.sh" --dataset atrocore --archive "${ARCH}" \
        --dest "${DEST}" 2>&1)"
eq "dry run deleted nothing" \
   "${COUNT_BEFORE}" "$(find "${ARCH}" -type f | wc -l | tr -d ' ')"
WOULD="$(printf '%s' "${DRY}" | sed -n 's/.*would remove \([0-9]*\) of.*/\1/p')"
# Anchor is segment 32; the archive holds 16..32, so 16 are before it.
eq "dry run predicts the right count" "16" "${WOULD}"

printf '\n%s=== 4. Apply%s\n' "${BLD}" "${RST}"

APPLIED="$("${SCRIPT_DIR}/prune-wal-archive.sh" --dataset atrocore --archive "${ARCH}" \
            --dest "${DEST}" --yes 2>&1)"
eq "apply exits zero" "0" "$?"
REMOVED="$(printf '%s' "${APPLIED}" | sed -n 's/.*removed \([0-9]*\) segment.*/\1/p')"
eq "apply removed exactly what the dry run predicted" "${WOULD}" "${REMOVED}"

if [ -f "${ARCH}/$(seg 32)" ]; then
  ok "the anchor segment itself survives"
else
  no "the anchor segment was deleted — the oldest retained base backup can no longer replay"
fi
KEPT=1
for i in $(seq 33 40); do
  [ -f "${ARCH}/$(seg "${i}")" ] || KEPT=0
done
if [ "${KEPT}" -eq 1 ]; then
  ok "every segment after the anchor survives"
else
  no "a segment newer than the anchor was deleted — replay would stop short"
fi
if [ -f "${ARCH}/00000002.history" ]; then
  ok "timeline history files survive"
else
  no ".history was deleted — timeline history is needed to follow a branch"
fi
GONE=1
for i in $(seq 16 31); do
  [ -f "${ARCH}/$(seg "${i}")" ] && GONE=0
done
if [ "${GONE}" -eq 1 ]; then
  ok "every segment before the anchor is gone"
else
  no "segments older than the anchor survived the prune"
fi

# Re-running must be a no-op, because the nightly job runs it every night.
AGAIN="$("${SCRIPT_DIR}/prune-wal-archive.sh" --dataset atrocore --archive "${ARCH}" \
          --dest "${DEST}" --yes 2>&1)"
if printf '%s' "${AGAIN}" | grep -q 'nothing to remove'; then
  ok "a second run is a no-op"
else
  no "a second run was not idempotent: $(printf '%s' "${AGAIN}" | tail -2)"
fi

echo ""
if [ "${FAIL}" -gt 0 ]; then
  printf '%s%d passed, %d FAILED%s\n' "${RED}" "${PASS}" "${FAIL}" "${RST}"
  exit 1
fi
printf '%s%d checks passed — WAL retention cuts at the oldest retained base backup.%s\n' "${GRN}" "${PASS}" "${RST}"
