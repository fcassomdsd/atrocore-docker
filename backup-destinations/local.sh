#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Backup destination: a local path.
#
# For a second disk, an NFS or SMB mount, or an attached USB drive.
#
#   BACKUP_DEST_PATH   required. The directory sets are written under.
#
# A path on the SAME disk as the data is not offsite and protects against
# nothing this exists for. Nothing here can tell the difference; only the
# operator can.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/set-age.sh"

VERB="${1:-}"; shift || true
ROOT="${BACKUP_DEST_PATH:-}"

need_root() {
  [ -n "${ROOT}" ] || { echo "local: BACKUP_DEST_PATH is not set" >&2; exit 2; }
}

case "${VERB}" in
  capabilities)
    echo "name=local path"
    echo "fetch=yes"
    echo "prune=yes"
    ;;

  push)
    need_root
    SRC="${1:?push needs <set-dir>}"; ID="${2:?push needs <set-id>}"
    mkdir -p "${ROOT}/${ID}"
    # Everything except the completeness marker first, the marker last: a
    # set carrying it is treated as complete, so it must be the last thing to
    # appear even on a destination where a copy is unlikely to fail.
    # "Unlikely" is how a full disk gets discovered during a restore.
    #
    # An ENCRYPTED set has no plaintext MANIFEST -- its index is the marker.
    # Written as an `if` rather than `[ -f x ] && cp`, because that form was
    # the LAST command in this branch: with no MANIFEST present the test was
    # false, the branch returned 1, and the driver reported "push failed"
    # having copied every byte correctly.
    MARKER=MANIFEST
    [ -f "${SRC}/MANIFEST" ] || MARKER=ENCRYPTED
    find "${SRC}" -maxdepth 1 -type f ! -name "${MARKER}" -print0 \
      | xargs -0 -I{} cp -f {} "${ROOT}/${ID}/"
    if [ -f "${SRC}/${MARKER}" ]; then
      cp -f "${SRC}/${MARKER}" "${ROOT}/${ID}/${MARKER}"
    fi
    ;;

  pull)
    need_root
    ID="${1:?pull needs <set-id>}"; DEST="${2:?pull needs <dest-dir>}"
    [ -d "${ROOT}/${ID}" ] || { echo "local: no such set: ${ID}" >&2; exit 1; }
    mkdir -p "${DEST}"
    cp -f "${ROOT}/${ID}"/* "${DEST}/"
    ;;

  list)
    [ -n "${ROOT}" ] && [ -d "${ROOT}" ] || exit 0
    # Not -printf: that is GNU-only, and this may run anywhere. BusyBox
    # find has no such flag and would simply error, listing nothing.
    find "${ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | sort
    ;;

  prune)
    need_root
    KEEP="${1:?prune needs <keep-days>}"
    pruned=0
    while IFS= read -r id; do
      [ -n "${id}" ] || continue
      if set_is_older_than "${id}" "${KEEP}"; then
        rm -rf "${ROOT:?}/${id}" && pruned=$((pruned + 1))
      fi
    done < <(find "${ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | sort)
    echo "${pruned}"
    ;;

  *) echo "local: unknown verb '${VERB}'" >&2; exit 2 ;;
esac
