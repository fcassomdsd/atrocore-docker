#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Conformance test for offsite backup encryption (P3.4).
#
#   scripts/verify-backup-encryption.sh
#
# Synthetic fixtures and the `local` driver, so it needs no cloud tenancy, no
# network and no real backup set. It needs `age`.
#
# WHAT IT IS ACTUALLY TESTING
#
# Not "does age encrypt things". The properties that decide whether this is
# worth having:
#
#   - the destination receives ciphertext and NOTHING else -- no stray
#     plaintext file, and no plaintext MANIFEST leaking names and hashes;
#   - an offsite copy can be verified with NO private key, because a routine
#     integrity check that requires an escrow retrieval will not be run;
#   - a pull with the key reproduces the original bytes exactly;
#   - the host refuses to push if the private key is sitting here, because
#     that silently discards the one property public-key encryption buys;
#   - a private key pasted into the recipient variable is refused outright,
#     since by then it is already in this host's environment;
#   - with two recipients in different custody, EITHER key opens the set --
#     the property that makes escrow survivable, and the one a typo in the
#     second key would silently remove.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFSITE="${SCRIPT_DIR}/backup-offsite.sh"

RED=$'\033[31m'; GRN=$'\033[32m'; BLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; BLD=""; RST=""; }
PASS=0; FAIL=0
ok() { printf '    %sok%s   %s\n' "${GRN}" "${RST}" "$*"; PASS=$((PASS + 1)); }
no() { printf '    %sFAIL%s %s\n' "${RED}" "${RST}" "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n%s=== %s%s\n' "${BLD}" "$*" "${RST}"; }

command -v age >/dev/null 2>&1 || { echo "needs 'age' (apk add age / apt install age)" >&2; exit 1; }

WORK="$(mktemp -d -t backup-enc-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT INT TERM

# A set shaped like backup-platform.sh's, small enough to be instant.
SET_ID="20260930T030000Z"
SRC="${WORK}/backups/${SET_ID}"
mkdir -p "${SRC}"
printf 'pretend pg_dump of atrocore\n' > "${SRC}/atrocore.dump"
printf 'pretend pg_dump of alfresco\n' > "${SRC}/alfresco.dump"
printf 'pretend content store tarball\n' > "${SRC}/alf_data.tar.gz"
{
  echo "# compliance-platform backup set"
  echo "created_utc: ${SET_ID}"
  echo "files:"
  for f in "${SRC}"/*; do
    [ "$(basename "$f")" = "MANIFEST" ] && continue
    echo "  - name: $(basename "$f")"
    echo "    bytes: $(stat -c %s "$f")"
    echo "    sha256: $(sha256sum "$f" | cut -d' ' -f1)"
  done
} > "${SRC}/MANIFEST"
SRC_FINGERPRINT="$(cd "${SRC}" && sha256sum ./* | sha256sum | cut -d' ' -f1)"

age-keygen -o "${WORK}/escrow.key" 2>/dev/null
RECIPIENT="$(age-keygen -y "${WORK}/escrow.key")"

DEST="${WORK}/offsite"
mkdir -p "${DEST}"
run() { # run <verb...> -- with the destination and recipient configured
  BACKUP_DESTINATION=local BACKUP_DEST_PATH="${DEST}" \
  BACKUP_DIR="${WORK}/backups" BACKUP_AGE_RECIPIENT="${RECIPIENT}" \
  BACKUP_AGE_IDENTITY_FILE="${IDENTITY:-}" \
    bash "${OFFSITE}" "$@" 2>&1
}

printf '%sbackup encryption conformance%s\n' "${BLD}" "${RST}"

step "1. Push encrypts"
IDENTITY="" OUT="$(run push --set "${SRC}")"; RC=$?
[ ${RC} -eq 0 ] && ok "push succeeded" || { no "push failed: ${OUT}"; }
printf '%s' "${OUT}" | grep -q 'encrypted to age1' \
  && ok "says what it encrypted to" || no "push did not report the recipient"

step "2. The destination holds ciphertext and nothing else"
LEFT="$(cd "${DEST}/${SET_ID}" 2>/dev/null && ls | sort | tr '\n' ' ')"
if [ -z "${LEFT}" ]; then
  no "nothing arrived at the destination"
else
  STRAY=0
  for f in "${DEST}/${SET_ID}"/*; do
    case "$(basename "${f}")" in
      *.age|ENCRYPTED) ;;
      *) no "plaintext file reached the destination: $(basename "${f}")"; STRAY=1 ;;
    esac
  done
  [ "${STRAY}" -eq 0 ] && ok "only *.age and the index: ${LEFT}"
  # The MANIFEST names every file and carries plaintext hashes. It must be
  # encrypted like anything else, or the destination learns the shape of the
  # data and can confirm a guessed file byte-for-byte.
  [ -f "${DEST}/${SET_ID}/MANIFEST" ] \
    && no "the MANIFEST arrived in plaintext" \
    || ok "the MANIFEST is encrypted too"
  grep -rqi 'pretend' "${DEST}/${SET_ID}"/*.age 2>/dev/null \
    && no "plaintext content is readable inside a .age file" \
    || ok "no plaintext content survives in the ciphertext"
fi

step "3. Verify needs no key"
IDENTITY="" OUT="$(run verify "${SET_ID}")"; RC=$?
[ ${RC} -eq 0 ] && ok "verify passed without the private key" || no "verify failed: ${OUT}"
printf '%s' "${OUT}" | grep -q 'no key needed' \
  && ok "says the check needed no key" || no "verify did not report keyless verification"

step "4. Tampering is caught, still without a key"
FIRST_AGE="$(find "${DEST}/${SET_ID}" -name '*.age' | sort | head -1)"
cp "${FIRST_AGE}" "${WORK}/intact.age"
printf 'corruption' >> "${FIRST_AGE}"
IDENTITY="" OUT="$(run verify "${SET_ID}")"; RC=$?
[ ${RC} -ne 0 ] && ok "a modified ciphertext file fails verification" || no "tampering went undetected"
cp "${WORK}/intact.age" "${FIRST_AGE}"

step "5. Pull with the escrowed key reproduces the original"
IDENTITY="${WORK}/escrow.key" OUT="$(run pull "${SET_ID}" --into "${WORK}/restored")"; RC=$?
if [ ${RC} -ne 0 ]; then
  no "pull failed: ${OUT}"
else
  ok "pull and decrypt succeeded"
  GOT="$(cd "${WORK}/restored" && sha256sum ./* | sha256sum | cut -d' ' -f1)"
  [ "${GOT}" = "${SRC_FINGERPRINT}" ] \
    && ok "the decrypted set is byte-identical to the original" \
    || no "the decrypted set differs from the original"
  find "${WORK}/restored" -name '*.age' | grep -q . \
    && no "encrypted files were left behind after decryption" \
    || ok "no .age files left behind"
fi

step "6. Two recipients: either key opens the set"
# The escrow shape worth recommending -- an operations key in a vault and a
# break-glass key on paper -- only works if both really do decrypt. A typo in
# the second would otherwise produce sets that only the first can open, which
# is the single point of failure the second key exists to remove.
age-keygen -o "${WORK}/second.key" 2>/dev/null
RECIPIENT_2="$(age-keygen -y "${WORK}/second.key")"
BOTH="${RECIPIENT} ${RECIPIENT_2}"
DEST2="${WORK}/offsite2"; mkdir -p "${DEST2}"
run2() {
  BACKUP_DESTINATION=local BACKUP_DEST_PATH="${DEST2}" \
  BACKUP_DIR="${WORK}/backups" BACKUP_AGE_RECIPIENT="${BOTH}" \
  BACKUP_AGE_IDENTITY_FILE="${IDENTITY:-}" \
    bash "${OFFSITE}" "$@" 2>&1
}
IDENTITY="" OUT="$(run2 push --set "${SRC}")"; RC=$?
[ ${RC} -eq 0 ] && ok "push to two recipients succeeded" || no "push failed: ${OUT}"
printf '%s' "${OUT}" | grep -q '2 recipients' \
  && ok "  ...and says there are two" || no "push did not report the recipient count"
grep -q "^recipients: 2$" "${DEST2}/${SET_ID}/${ENC_INDEX:-ENCRYPTED}" 2>/dev/null \
  && ok "the index records both recipients" || no "the index does not record both recipients"

for which in first:escrow.key second:second.key; do
  label="${which%%:*}"; keyfile="${which##*:}"
  rm -rf "${WORK}/r-${label}"
  IDENTITY="${WORK}/${keyfile}" OUT="$(run2 pull "${SET_ID}" --into "${WORK}/r-${label}")"; RC=$?
  if [ ${RC} -ne 0 ]; then
    no "the ${label} key could not open the set: $(printf '%s' "${OUT}" | tail -1)"
  else
    GOT="$(cd "${WORK}/r-${label}" && sha256sum ./* | sha256sum | cut -d' ' -f1)"
    [ "${GOT}" = "${SRC_FINGERPRINT}" ] \
      && ok "the ${label} key alone reproduces the original" \
      || no "the ${label} key decrypted to something other than the original"
  fi
done

# One bad entry must not be carried by the good one.
OUT="$(BACKUP_DESTINATION=local BACKUP_DEST_PATH="${DEST2}" BACKUP_DIR="${WORK}/backups" \
       BACKUP_AGE_RECIPIENT="${RECIPIENT} age1-this-is-not-a-key" \
       bash "${OFFSITE}" push --set "${SRC}" 2>&1)"; RC=$?
[ ${RC} -ne 0 ] && ok "a malformed second recipient is refused" \
                || no "a malformed second recipient was accepted"
# Asserting only "refused" is not enough: age itself rejects a bad key later
# in the run, so the test passed even when validation checked only the FIRST
# recipient. The distinction matters -- our refusal names the offending entry
# before anything is encrypted or sent, age's does not.
printf '%s' "${OUT}" | grep -q 'age will not accept as a public key' \
  && ok "  ...by our own validation, naming it" \
  || no "the refusal came from age, not from recipient validation — a bad entry past the first is not being checked"

step "7. Refusals"
rm -rf "${WORK}/nokey"
IDENTITY="" OUT="$(run pull "${SET_ID}" --into "${WORK}/nokey")"; RC=$?
[ ${RC} -ne 0 ] && ok "pull without the key fails" || no "pull without the key succeeded"
printf '%s' "${OUT}" | grep -q 'escrow' \
  && ok "  ...and points at escrow" || no "pull failure did not mention escrow"

# Pushing while the private key is on this host discards the entire point.
IDENTITY="${WORK}/escrow.key" OUT="$(run push --set "${SRC}")"; RC=$?
[ ${RC} -ne 0 ] && ok "push refuses while the private key is on this host" \
                || no "push proceeded with the private key present"
# Matched on a phrase that does not straddle the message's line wrap: the
# first version grepped 'cannot read its own backups', which the refusal
# splits across two lines, so the assertion failed on a correct message.
printf '%s' "${OUT}" | grep -q 'PRIVATE key is present on this host' \
  && ok "  ...and says why" || no "the refusal did not explain itself"

# A private key pasted into the recipient variable.
SECRET="$(grep -m1 '^AGE-SECRET-KEY-' "${WORK}/escrow.key")"
OUT="$(BACKUP_DESTINATION=local BACKUP_DEST_PATH="${DEST}" BACKUP_DIR="${WORK}/backups" \
       BACKUP_AGE_RECIPIENT="${SECRET}" bash "${OFFSITE}" push --set "${SRC}" 2>&1)"; RC=$?
[ ${RC} -ne 0 ] && ok "a PRIVATE key in BACKUP_AGE_RECIPIENT is refused" \
                || no "a private key was accepted as a recipient"
printf '%s' "${OUT}" | grep -qi 'rotate' \
  && ok "  ...and says to rotate it" || no "the refusal did not say to rotate the exposed key"

echo ""
if [ "${FAIL}" -gt 0 ]; then
  printf '%s%d passed, %d FAILED%s\n' "${RED}" "${PASS}" "${FAIL}" "${RST}"
  exit 1
fi
printf '%s%d checks passed — the offsite copy is ciphertext, verifiable without the key, and restorable with it.%s\n' "${GRN}" "${PASS}" "${RST}"
