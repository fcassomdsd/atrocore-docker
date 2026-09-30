#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Backup destination: another host over SSH.
#
# The realistic default for an authority with a second building or a second
# rack, and the only one of the three shipped drivers that needs no cloud
# account and no object store.
#
#   BACKUP_DEST_SSH     required. user@host, as ssh takes it.
#   BACKUP_DEST_PATH    required. Absolute path on that host.
#   BACKUP_SSH_KEY      optional. Identity file. Follows the platform's
#                       secret convention: point it at a mounted key file
#                       rather than embedding one.
#   BACKUP_SSH_PORT     optional, default 22.
#   BACKUP_SSH_OPTS     optional. Extra ssh options, appended last.
#
# Authentication is key-based only. There is no password prompt and there
# must not be: this runs unattended from a timer, and a driver that can
# block on a prompt is a backup that silently stops happening.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/set-age.sh"

VERB="${1:-}"; shift || true
TARGET="${BACKUP_DEST_SSH:-}"
ROOT="${BACKUP_DEST_PATH:-}"
PORT="${BACKUP_SSH_PORT:-22}"

need_config() {
  [ -n "${TARGET}" ] || { echo "rsync-ssh: BACKUP_DEST_SSH is not set" >&2; exit 2; }
  [ -n "${ROOT}" ]   || { echo "rsync-ssh: BACKUP_DEST_PATH is not set" >&2; exit 2; }
}

ssh_cmd() {
  # BatchMode: fail instead of prompting. See the note above.
  local c="ssh -p ${PORT} -o BatchMode=yes"
  [ -n "${BACKUP_SSH_KEY:-}" ] && c="${c} -i ${BACKUP_SSH_KEY}"
  [ -n "${BACKUP_SSH_OPTS:-}" ] && c="${c} ${BACKUP_SSH_OPTS}"
  printf '%s' "${c}"
}

remote() { eval "$(ssh_cmd)" "${TARGET}" "$@"; }

case "${VERB}" in
  capabilities)
    echo "name=rsync over ssh"
    echo "fetch=yes"
    echo "prune=yes"
    ;;

  push)
    need_config
    SRC="${1:?push needs <set-dir>}"; ID="${2:?push needs <set-id>}"
    remote "mkdir -p '${ROOT}/${ID}'"
    # Two passes so MANIFEST lands last. rsync would otherwise send files in
    # whatever order it likes, and an interrupted transfer that happened to
    # have sent MANIFEST already would leave a partial set looking complete.
    MARKER=MANIFEST
    [ -f "${SRC}/MANIFEST" ] || MARKER=ENCRYPTED
    rsync -a --delete --exclude "${MARKER}" -e "$(ssh_cmd)" \
      "${SRC}/" "${TARGET}:${ROOT}/${ID}/"
    if [ -f "${SRC}/${MARKER}" ]; then
      rsync -a -e "$(ssh_cmd)" "${SRC}/${MARKER}" "${TARGET}:${ROOT}/${ID}/${MARKER}"
    fi
    ;;

  pull)
    need_config
    ID="${1:?pull needs <set-id>}"; DEST="${2:?pull needs <dest-dir>}"
    mkdir -p "${DEST}"
    rsync -a -e "$(ssh_cmd)" "${TARGET}:${ROOT}/${ID}/" "${DEST}/"
    ;;

  list)
    need_config
    # `|| true` on the remote: an empty or absent root is "no sets", not an
    # error. A first run should not look like a failure.
    remote "ls -1 '${ROOT}' 2>/dev/null || true" | sort
    ;;

  prune)
    need_config
    KEEP="${1:?prune needs <keep-days>}"
    pruned=0
    while IFS= read -r id; do
      id="$(printf '%s' "${id}" | tr -d '\r')"
      [ -n "${id}" ] || continue
      if set_is_older_than "${id}" "${KEEP}"; then
        # Quoted and anchored under ROOT. An id is only ever a timestamp;
        # anything else fails set_is_older_than and is never reached.
        remote "rm -rf '${ROOT}/${id}'" && pruned=$((pruned + 1))
      fi
    done < <(remote "ls -1 '${ROOT}' 2>/dev/null || true" | sort)
    echo "${pruned}"
    ;;

  *) echo "rsync-ssh: unknown verb '${VERB}'" >&2; exit 2 ;;
esac
