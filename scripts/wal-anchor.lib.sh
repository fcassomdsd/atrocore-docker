#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Where WAL retention is allowed to stop: the oldest base backup you still
# keep. Sourced by prune-wal-archive.sh and ship-wal-archive.sh so the two
# cannot disagree about it.
#
# WHY AN ANCHOR AND NOT AN AGE
# ----------------------------
# "Delete WAL older than N days" is the obvious rule and it is wrong in both
# directions. Too small and it silently destroys point-in-time recovery from
# a base backup you are still keeping -- the segments the replay needs are
# gone, and nothing says so until a restore. Too large and the archive grows
# without bound, which is the state this platform was actually in: ~3 GB/day
# across three databases, unpruned, on a disk that reached 99%.
#
# The correct boundary is not a duration. A base backup can only be replayed
# forward from the WAL segment it started in, and that segment's name is
# written inside the backup itself, in backup_label:
#
#   START WAL LOCATION: 2/6C000028 (file 00000001000000020000006C)
#
# So the oldest segment worth keeping is the START WAL of the OLDEST base
# backup still retained. Everything before it can be removed: no backup you
# hold can replay onto it. Nothing after it may be, ever.
#
# This makes WAL retention follow set retention automatically. Prune a set and
# the anchor moves forward on the next run; keep a set longer and the WAL it
# needs is kept with it.

# wal_anchor_from_label <label-text>
# Extracts the START WAL segment name from backup_label contents.
wal_anchor_from_label() {
  printf '%s\n' "$1" \
    | sed -n 's/^START WAL LOCATION: [^(]*(file \([0-9A-Fa-f]\{24\}\)).*$/\1/p' \
    | head -n 1
}

# wal_anchor_for <dest-dir> <dataset>
# The oldest retained base backup's START WAL segment, or empty if there is
# no base backup for this dataset in <dest-dir>.
#
# Ordered by the SEGMENT part -- the last 16 characters -- and not by the
# whole filename, because that is what pg_archivecleanup itself compares. The
# leading 8 are the timeline ID, so a full-name sort would rank a segment on
# timeline 2 above an earlier one on timeline 1 and hand back an anchor that
# is further forward than the archive can safely be cut.
wal_anchor_for() {
  local dest="$1" dataset="$2" tar_file label seg
  [ -d "${dest}" ] || return 0
  while IFS= read -r tar_file; do
    [ -s "${tar_file}" ] || continue
    label="$(tar xOf "${tar_file}" backup_label 2>/dev/null)" || continue
    seg="$(wal_anchor_from_label "${label}")"
    [ -n "${seg}" ] && printf '%s %s\n' "${seg: -16}" "${seg}"
  done < <(find "${dest}" -mindepth 2 -maxdepth 2 -type f -name "${dataset}.basebackup.tar" 2>/dev/null) \
    | sort | head -n 1 | cut -d' ' -f2
}
