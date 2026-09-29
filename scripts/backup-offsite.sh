#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Move backup sets to and from an offsite destination.
#
# backup-platform.sh writes sets to a local directory. That is a backup of
# the data but not of the host: a fire, a stolen server or a failed array
# takes the sets with it. This is the other half.
#
#   scripts/backup-offsite.sh push   [--set <dir>]      # newest set by default
#   scripts/backup-offsite.sh pull   <set-id> [--into <dir>]
#   scripts/backup-offsite.sh list
#   scripts/backup-offsite.sh prune  [--keep-days N]
#   scripts/backup-offsite.sh verify <set-id>
#   scripts/backup-offsite.sh capabilities
#
#   BACKUP_DESTINATION   driver name, e.g. local | rsync-ssh | s3
#                        (a path is also accepted, for a driver kept outside
#                        this repository)
#   BACKUP_DIR           where local sets live. Default ../backups, matching
#                        backup-platform.sh.
#   BACKUP_RETENTION_DAYS  default 30, matching backup-platform.sh.
#
# Driver configuration is the driver's own; see backup-destinations/README.md.
#
# `verify` is the one worth knowing about: it pulls a set back from the
# destination into a temporary directory and re-checks every sha256 in its
# MANIFEST. An offsite copy nobody has ever read back is a hope, not a
# backup, and this is the cheapest way to stop it being one.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
DRIVER_DIR="${REPO_DIR}/backup-destinations"

BACKUP_DIR="${BACKUP_DIR:-${WORKSPACE}/backups}"
KEEP_DAYS="${BACKUP_RETENTION_DAYS:-30}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1" >&2; }
step()  { printf '\n=== %s\n' "$1"; }
ok()    { printf '    ok   %s\n' "$1"; }
info()  { printf '    ..   %s\n' "$1"; }
die()   { red "    FAIL $1"; exit 1; }

# --- resolve the driver ----------------------------------------------------
DEST_NAME="${BACKUP_DESTINATION:-}"
[ -n "${DEST_NAME}" ] || die "BACKUP_DESTINATION is not set.
         Available drivers: $(find "${DRIVER_DIR}" -maxdepth 1 -name '*.sh' -printf '%f\n' 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ')
         See backup-destinations/README.md"

if [ -x "${DEST_NAME}" ]; then
  DRIVER="${DEST_NAME}"                       # an out-of-tree driver
else
  DRIVER="${DRIVER_DIR}/${DEST_NAME}.sh"
fi
[ -x "${DRIVER}" ] || die "no driver '${DEST_NAME}' (looked for ${DRIVER})"

capability() { # capability <key> -> value, or empty
  "${DRIVER}" capabilities 2>/dev/null | sed -n "s/^$1=//p" | head -1
}

# --- args ------------------------------------------------------------------
VERB="${1:-}"; shift || true
SET_DIR=""; SET_ID=""; INTO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --set)        SET_DIR="${2:?--set needs a directory}"; shift 2 ;;
    --into)       INTO="${2:?--into needs a directory}"; shift 2 ;;
    --keep-days)  KEEP_DAYS="${2:?--keep-days needs a number}"; shift 2 ;;
    -*)           die "unknown option: $1" ;;
    *)            [ -z "${SET_ID}" ] && SET_ID="$1" || die "unexpected argument: $1"; shift ;;
  esac
done

newest_local_set() {
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1
}

# Re-check every checksum the set claims. Shared by push (before sending)
# and verify (after fetching), because the interesting question is the same
# in both directions: does this set still describe itself?
check_manifest() { # check_manifest <dir> -> 0 if every file matches
  local dir="$1" bad=0 checked=0 name want have
  [ -f "${dir}/MANIFEST" ] || { red "    no MANIFEST in ${dir}"; return 1; }
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    want="$(grep -A2 "name: ${name}\$" "${dir}/MANIFEST" | sed -n 's/.*sha256: //p' | head -1)"
    have="$(sha256sum "${dir}/${name}" 2>/dev/null | cut -d' ' -f1)"
    checked=$((checked + 1))
    if [ -z "${have}" ]; then red "    missing: ${name}"; bad=$((bad + 1))
    elif [ "${want}" != "${have}" ]; then red "    checksum mismatch: ${name}"; bad=$((bad + 1)); fi
  done < <(sed -n 's/^  - name: //p' "${dir}/MANIFEST")
  [ "${checked}" -gt 0 ] || { red "    MANIFEST lists no files"; return 1; }
  [ "${bad}" -eq 0 ] || return 1
  info "${checked} file(s) checksum-verified"
  return 0
}

case "${VERB}" in
  capabilities)
    "${DRIVER}" capabilities
    ;;

  push)
    [ -n "${SET_DIR}" ] || {
      id="$(newest_local_set)"
      [ -n "${id}" ] || die "no sets in ${BACKUP_DIR} — run backup-platform.sh first"
      SET_DIR="${BACKUP_DIR}/${id}"
    }
    SET_ID="$(basename "${SET_DIR}")"
    step "Push ${SET_ID} to ${DEST_NAME}"
    [ -d "${SET_DIR}" ] || die "no such set directory: ${SET_DIR}"
    # Verify before sending. Shipping a set that is already corrupt wastes
    # the transfer and, worse, produces an offsite copy that looks fine
    # until the day it is needed.
    check_manifest "${SET_DIR}" || die "the local set is not intact; not pushing it"
    "${DRIVER}" push "${SET_DIR}" "${SET_ID}" || die "driver push failed"
    ok "pushed ${SET_ID}"
    ;;

  pull)
    [ -n "${SET_ID}" ] || die "pull needs a set id (see: $0 list)"
    [ "$(capability fetch)" = "yes" ] || die "destination '${DEST_NAME}' is write-only (fetch=no); it cannot be read back"
    INTO="${INTO:-${BACKUP_DIR}/${SET_ID}}"
    step "Pull ${SET_ID} from ${DEST_NAME}"
    mkdir -p "${INTO}"
    "${DRIVER}" pull "${SET_ID}" "${INTO}" || die "driver pull failed"
    check_manifest "${INTO}" || die "the fetched set does not match its MANIFEST"
    ok "pulled to ${INTO}"
    ;;

  list)
    "${DRIVER}" list
    ;;

  prune)
    p="$(capability prune)"
    case "${p}" in
      self)
        info "destination '${DEST_NAME}' expires sets itself; not pruning from here"
        ;;
      no)
        info "destination '${DEST_NAME}' cannot prune; remove old sets by hand"
        ;;
      *)
        step "Prune sets older than ${KEEP_DAYS} days from ${DEST_NAME}"
        n="$("${DRIVER}" prune "${KEEP_DAYS}")" || die "driver prune failed"
        ok "pruned ${n:-0} set(s)"
        ;;
    esac
    ;;

  verify)
    [ -n "${SET_ID}" ] || {
      SET_ID="$("${DRIVER}" list | tail -1)"
      [ -n "${SET_ID}" ] || die "the destination holds no sets"
      info "no set given; verifying the newest: ${SET_ID}"
    }
    [ "$(capability fetch)" = "yes" ] \
      || die "destination '${DEST_NAME}' is write-only (fetch=no).
         It cannot be verified from here, and that is a property of the
         destination rather than a fault. Whatever assurance it offers has to
         come from the storage itself."
    step "Verify ${SET_ID} by reading it back from ${DEST_NAME}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP}"' EXIT INT TERM
    "${DRIVER}" pull "${SET_ID}" "${TMP}" || die "could not fetch ${SET_ID}"
    check_manifest "${TMP}" || die "the offsite copy of ${SET_ID} does not match its MANIFEST"
    green "Offsite copy of ${SET_ID} is intact."
    ;;

  ""|-h|--help)
    sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *) die "unknown verb '${VERB}'" ;;
esac
