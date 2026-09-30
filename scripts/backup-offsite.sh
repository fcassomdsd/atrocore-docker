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
#   BACKUP_AGE_RECIPIENT   an age PUBLIC key (age1...). When set, everything
#                        that leaves this host is encrypted to it.
#   BACKUP_AGE_IDENTITY_FILE  the escrowed PRIVATE key. Needed only to pull
#                        and decrypt. It must NOT live on this host in normal
#                        operation, and `push` refuses if it does.
#
# Driver configuration is the driver's own; see backup-destinations/README.md.
#
# `verify` is the one worth knowing about: it pulls a set back from the
# destination into a temporary directory and re-checks every sha256. An
# offsite copy nobody has ever read back is a hope, not a backup, and this is
# the cheapest way to stop it being one.
#
# ENCRYPTION, AND WHY IT IS PUBLIC-KEY
# ------------------------------------
# An offsite destination is by definition somewhere this platform does not
# control -- a cloud tenancy, a courier, a disk in another building. With
# BACKUP_AGE_RECIPIENT set, every file is encrypted to that recipient before
# a driver ever sees it, so the destination holds ciphertext and nothing else.
#
# The host holds only the PUBLIC key. It can therefore encrypt backups and
# cannot read any of them -- including the ones it made last year. That is
# the property worth having: whoever takes this machine gets the data that is
# on it, and not the backup history as well. `push` refuses to run if the
# private key is present here, because that silently gives the property away.
#
# Local sets stay in plaintext, deliberately. Decryption needs the escrowed
# key, and requiring an escrow retrieval for the ordinary same-host restore
# would add an unbounded delay to a recovery measured at 1m40s
# (scripts/measure-rto.sh). The threat this addresses is the offsite copy,
# and that is what it encrypts.
#
# `verify` needs NO key. Each encrypted set carries a plaintext ENCRYPTED
# index listing the sha256 of every *ciphertext* file, so the integrity of an
# offsite copy can be audited on a schedule without anyone retrieving the
# private key. Reading the contents needs the key; proving the bytes survived
# does not.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
DRIVER_DIR="${REPO_DIR}/backup-destinations"

BACKUP_DIR="${BACKUP_DIR:-${WORKSPACE}/backups}"
KEEP_DAYS="${BACKUP_RETENTION_DAYS:-30}"
AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
AGE_IDENTITY="${BACKUP_AGE_IDENTITY_FILE:-}"

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
    # Only the `files:` section -- see the note in restore-platform.sh.
  done < <(awk '/^files:/ {infiles=1; next} /^[^ #]/ {infiles=0} infiles && /^  - name: / {sub(/^  - name: /, ""); print}' "${dir}/MANIFEST")
  [ "${checked}" -gt 0 ] || { red "    MANIFEST lists no files"; return 1; }
  [ "${bad}" -eq 0 ] || return 1
  info "${checked} file(s) checksum-verified"
  return 0
}

# --- encryption ------------------------------------------------------------
ENC_INDEX="ENCRYPTED"

enc_enabled() { [ -n "${AGE_RECIPIENT}" ]; }

enc_preflight() { # shared by every verb that touches ciphertext
  command -v age >/dev/null 2>&1 \
    || die "BACKUP_AGE_RECIPIENT is set but 'age' is not installed — refusing to send plaintext to ${DEST_NAME}"
  # A private key in the recipient variable would encrypt the backups to a
  # key that is now sitting in this host's environment or, worse, its
  # repository. That is the exact failure this design exists to avoid, and it
  # is an easy paste to make.
  case "${AGE_RECIPIENT}" in
    AGE-SECRET-KEY-*) die "BACKUP_AGE_RECIPIENT holds a PRIVATE key. It takes a public key (age1...). Rotate that key: it has been in this host's environment." ;;
    age1*) ;;
    *) die "BACKUP_AGE_RECIPIENT does not look like an age public key (expected age1...)" ;;
  esac
}

# The plaintext side of an encrypted set: enough to prove the bytes arrived
# intact, and nothing about what they contain.
enc_write_index() { # enc_write_index <dir> <set-id>
  local dir="$1" id="$2" f
  {
    echo "# compliance-platform encrypted set"
    echo "set: ${id}"
    echo "encrypted_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "tool: age"
    echo "recipient: ${AGE_RECIPIENT}"
    echo "# sha256 below are of the CIPHERTEXT, so an offsite copy can be"
    echo "# verified without the escrowed private key."
    echo "files:"
    for f in "${dir}"/*.age; do
      [ -e "${f}" ] || continue
      echo "  - name: $(basename "${f}")"
      echo "    bytes: $(stat -c %s "${f}")"
      echo "    sha256: $(sha256sum "${f}" | cut -d' ' -f1)"
    done
  } > "${dir}/${ENC_INDEX}"
}

encrypt_set() { # encrypt_set <src set dir> <dst dir> <set-id>
  local src="$1" dst="$2" id="$3" f n
  mkdir -p "${dst}"
  n=0
  for f in "${src}"/*; do
    [ -f "${f}" ] || continue
    age -r "${AGE_RECIPIENT}" -o "${dst}/$(basename "${f}").age" "${f}" \
      || die "age failed on $(basename "${f}")"
    n=$((n + 1))
  done
  [ "${n}" -gt 0 ] || die "nothing to encrypt in ${src}"
  enc_write_index "${dst}" "${id}"
  info "${n} file(s) encrypted to ${AGE_RECIPIENT}"
}

# Verifiable with no key at all -- the point of the plaintext index.
check_enc_index() { # check_enc_index <dir>
  local dir="$1" bad=0 checked=0 name want have
  [ -f "${dir}/${ENC_INDEX}" ] || { red "    no ${ENC_INDEX} in ${dir}"; return 1; }
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    want="$(grep -A2 "name: ${name}\$" "${dir}/${ENC_INDEX}" | sed -n 's/.*sha256: //p' | head -1)"
    have="$(sha256sum "${dir}/${name}" 2>/dev/null | cut -d' ' -f1)"
    checked=$((checked + 1))
    if [ -z "${have}" ]; then red "    missing: ${name}"; bad=$((bad + 1))
    elif [ "${want}" != "${have}" ]; then red "    ciphertext checksum mismatch: ${name}"; bad=$((bad + 1)); fi
  done < <(awk '/^files:/ {infiles=1; next} /^[^ #]/ {infiles=0} infiles && /^  - name: / {sub(/^  - name: /, ""); print}' "${dir}/${ENC_INDEX}")
  [ "${checked}" -gt 0 ] || { red "    ${ENC_INDEX} lists no files"; return 1; }
  [ "${bad}" -eq 0 ] || return 1
  info "${checked} encrypted file(s) checksum-verified (no key needed)"
  return 0
}

decrypt_set() { # decrypt_set <dir>  -- in place, .age removed on success
  local dir="$1" f out n=0
  [ -n "${AGE_IDENTITY}" ] \
    || die "this set is encrypted and BACKUP_AGE_IDENTITY_FILE is not set.
         The private key is deliberately not kept on this host; retrieve it
         from escrow and point BACKUP_AGE_IDENTITY_FILE at it."
  [ -f "${AGE_IDENTITY}" ] || die "BACKUP_AGE_IDENTITY_FILE does not exist: ${AGE_IDENTITY}"
  command -v age >/dev/null 2>&1 || die "'age' is not installed; cannot decrypt"
  for f in "${dir}"/*.age; do
    [ -e "${f}" ] || continue
    out="${f%.age}"
    age -d -i "${AGE_IDENTITY}" -o "${out}" "${f}" \
      || die "could not decrypt $(basename "${f}") — wrong key, or the file is damaged"
    rm -f "${f}"
    n=$((n + 1))
  done
  [ "${n}" -gt 0 ] || die "nothing to decrypt in ${dir}"
  rm -f "${dir}/${ENC_INDEX}"
  info "${n} file(s) decrypted"
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
    if enc_enabled; then
      enc_preflight
      # The whole point of encrypting to a public key is that this host
      # cannot read the result. If the private key is here too, the
      # destination is protected and the host is not, and nobody finds out
      # until the host is the thing that was taken.
      if [ -n "${AGE_IDENTITY}" ] && [ -f "${AGE_IDENTITY}" ]; then
        die "the escrowed PRIVATE key is present on this host (${AGE_IDENTITY}).
         Public-key backup encryption exists so this machine cannot read its
         own backups; keeping the identity here gives that away. Remove it,
         or unset BACKUP_AGE_IDENTITY_FILE for push."
      fi
      STAGE="$(mktemp -d)"
      trap 'rm -rf "${STAGE}"' EXIT INT TERM
      encrypt_set "${SET_DIR}" "${STAGE}" "${SET_ID}"
      "${DRIVER}" push "${STAGE}" "${SET_ID}" || die "driver push failed"
      ok "pushed ${SET_ID} (encrypted to ${AGE_RECIPIENT})"
    else
      # Said every time, not once in a README: an unencrypted set on someone
      # else's storage is a copy of the whole platform in the clear.
      info "BACKUP_AGE_RECIPIENT is not set — this set goes to ${DEST_NAME} UNENCRYPTED"
      "${DRIVER}" push "${SET_DIR}" "${SET_ID}" || die "driver push failed"
      ok "pushed ${SET_ID}"
    fi
    ;;

  pull)
    [ -n "${SET_ID}" ] || die "pull needs a set id (see: $0 list)"
    [ "$(capability fetch)" = "yes" ] || die "destination '${DEST_NAME}' is write-only (fetch=no); it cannot be read back"
    INTO="${INTO:-${BACKUP_DIR}/${SET_ID}}"
    step "Pull ${SET_ID} from ${DEST_NAME}"
    mkdir -p "${INTO}"
    "${DRIVER}" pull "${SET_ID}" "${INTO}" || die "driver pull failed"
    # Two layers, each doing its own job: the ciphertext index proves the
    # bytes survived the round trip, and the set's own MANIFEST proves the
    # plaintext is what was backed up.
    if [ -f "${INTO}/${ENC_INDEX}" ]; then
      check_enc_index "${INTO}" || die "the fetched set does not match its ${ENC_INDEX}"
      decrypt_set "${INTO}"
    fi
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
    if [ -f "${TMP}/${ENC_INDEX}" ]; then
      # Deliberately does NOT decrypt. Integrity is checkable without the
      # escrowed key, so this can run on a schedule without anyone taking the
      # private key out of escrow to satisfy a routine check.
      check_enc_index "${TMP}" || die "the offsite copy of ${SET_ID} does not match its ${ENC_INDEX}"
      green "Offsite copy of ${SET_ID} is intact (encrypted; contents not read)."
    else
      check_manifest "${TMP}" || die "the offsite copy of ${SET_ID} does not match its MANIFEST"
      green "Offsite copy of ${SET_ID} is intact."
    fi
    ;;

  ""|-h|--help)
    sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *) die "unknown verb '${VERB}'" ;;
esac
