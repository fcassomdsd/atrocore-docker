#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Conformance test for a backup destination driver.
#
#   BACKUP_DESTINATION=local BACKUP_DEST_PATH=/mnt/backup \
#     ./scripts/verify-backup-destination.sh
#
# WHY THIS EXISTS
# ---------------
# This platform ships three drivers and can test three drivers. An adopting
# authority may back up to a national cloud, a tape robot, an Azure tenancy
# or a NAS in another building, and nobody here can run any of those. A
# driver that has never been exercised against the storage it targets is a
# guess -- and the first time anyone finds out is a restore.
#
# So: we verify the contract, you verify your backend. This is the script
# that makes "pluggable" a property rather than a claim.
#
# POINT IT AT A SCRATCH DESTINATION, NOT YOUR REAL ONE
# ----------------------------------------------------
# This exercises `prune`, which means it deletes sets. It refuses to start
# if the destination already holds anything that is not one of its own
# synthetic sets -- but that guard is the only thing between this script and
# your backups, so use a scratch bucket or a scratch path with the same
# credentials. Validating the driver is the goal; the storage behind it can
# be empty.
#
# It uses SYNTHETIC sets with their own MANIFEST. Everything it creates is
# removed at the end, including on failure.
#
#   --keep    leave the synthetic sets behind, to inspect what landed
#   --force   run even if the destination holds other sets. Only do this
#             if you are certain none of them matter.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_DIR="${REPO_DIR}/backup-destinations"
KEEP=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --keep)  KEEP=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

PASSED=0; FAILED=0
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1" >&2; }
step()  { printf '\n=== %s\n' "$1"; }
ok()    { PASSED=$((PASSED+1)); printf '    ok   %s\n' "$1"; }
no()    { FAILED=$((FAILED+1)); red "    FAIL $1"; }
info()  { printf '    ..   %s\n' "$1"; }

DEST_NAME="${BACKUP_DESTINATION:-}"
[ -n "${DEST_NAME}" ] || { red "BACKUP_DESTINATION is not set"; exit 2; }
if [ -x "${DEST_NAME}" ]; then DRIVER="${DEST_NAME}"; else DRIVER="${DRIVER_DIR}/${DEST_NAME}.sh"; fi
[ -x "${DRIVER}" ] || { red "no driver '${DEST_NAME}' (looked for ${DRIVER})"; exit 2; }

WORK="$(mktemp -d)"
# A current id and one dated 1999. The current one must survive `prune 30`
# and be removed by `prune 0`; the 1999 one must be removed by both. Between
# them they distinguish a driver that dates sets by their id from one that
# dates them by file mtime -- the second would keep the 1999 set, because it
# was written seconds ago.
# An hour ago, not "now". `prune 0` means "older than this instant", and a
# set stamped with the current second is not older than the same second --
# on a fast machine the whole test runs inside one, so cleanup silently left
# the set behind. Caught by running this in a bare Alpine container, where
# it is quicker than on a developer's machine. An hour is comfortably in the
# past for `prune 0` and comfortably inside any sane retention window.
_now="$(date -u +%s)"
NOW_ID="$(date -u -d "@$((_now - 3600))" +%Y%m%dT%H%M%SZ 2>/dev/null \
       || date -u -r "$((_now - 3600))" +%Y%m%dT%H%M%SZ)"
OLD_ID="19990101T000000Z"
CREATED=""

cleanup() {
  # prune 0 means "older than now", which both synthetic ids satisfy. Run on
  # every exit path, so an interrupted test does not leave sets behind.
  if [ "${KEEP}" -eq 0 ] && [ -n "${CREATED}" ]; then
    "${DRIVER}" prune 0 >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

# --- the guard -------------------------------------------------------------
# prune deletes things. Running this against a live destination would delete
# real backup sets, so refuse unless the destination is empty of anything
# that is not ours.
EXISTING="$("${DRIVER}" list 2>/dev/null | grep -vx -e "${NOW_ID}" -e "${OLD_ID}" | grep -v '^$' || true)"
if [ -n "${EXISTING}" ] && [ "${FORCE}" -eq 0 ]; then
  red "Refusing to run: '${DEST_NAME}' already holds sets that are not this test's."
  red ""
  printf '%s\n' "${EXISTING}" | head -5 | sed 's/^/      /' >&2
  red ""
  red "This test exercises prune, which deletes sets. Point it at a scratch"
  red "path or bucket with the same credentials -- validating the driver does"
  red "not need real data behind it. Use --force only if none of the above"
  red "matter."
  exit 2
fi

make_set() { # make_set <dir>
  local d="$1"; mkdir -p "${d}"
  printf 'synthetic database dump\n%s\n' "$(head -c 256 /dev/urandom | base64)" > "${d}/atrocore.dump"
  printf 'synthetic content store\n' > "${d}/alf_data.tar.gz"
  {
    echo "created_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "note: SYNTHETIC set written by verify-backup-destination.sh"
    echo "files:"
    for f in atrocore.dump alf_data.tar.gz; do
      echo "  - name: ${f}"
      echo "    sha256: $(sha256sum "${d}/${f}" | cut -d' ' -f1)"
    done
  } > "${d}/MANIFEST"
}

# ---------------------------------------------------------------------------
step "1. capabilities"
CAPS="$("${DRIVER}" capabilities 2>/dev/null)"
[ -n "${CAPS}" ] && ok "driver answers capabilities" || no "capabilities produced nothing"
FETCH="$(printf '%s' "${CAPS}" | sed -n 's/^fetch=//p' | head -1)"
PRUNE="$(printf '%s' "${CAPS}" | sed -n 's/^prune=//p' | head -1)"
case "${FETCH}" in yes|no) ok "fetch=${FETCH}" ;; *) no "fetch must be yes or no, got '${FETCH}'" ;; esac
case "${PRUNE}" in yes|no|self) ok "prune=${PRUNE}" ;; *) no "prune must be yes, no or self, got '${PRUNE}'" ;; esac

# ---------------------------------------------------------------------------
step "2. push"
make_set "${WORK}/src"
if "${DRIVER}" push "${WORK}/src" "${NOW_ID}" >/dev/null 2>&1; then
  ok "pushed a set"; CREATED="${CREATED} ${NOW_ID}"
else
  no "push failed"
fi

# Idempotency matters because a timer that retries after a partial failure
# must not need a human to clean up first.
if "${DRIVER}" push "${WORK}/src" "${NOW_ID}" >/dev/null 2>&1; then
  ok "pushing the same set again succeeds (idempotent)"
else
  no "re-pushing an existing set failed; a retry would need manual cleanup"
fi

# ---------------------------------------------------------------------------
step "3. list"
LISTED="$("${DRIVER}" list 2>/dev/null)"
if printf '%s\n' "${LISTED}" | grep -qx "${NOW_ID}"; then ok "list includes the pushed set"; else no "list does not include ${NOW_ID}"; fi
if printf '%s\n' "${LISTED}" | grep -qvE '^[0-9]{8}T[0-9]{6}Z$|^$'; then
  info "list contains entries that are not set ids — prune cannot date those, and will leave them alone"
fi

# ---------------------------------------------------------------------------
step "4. pull, and every byte compared"
if [ "${FETCH}" = "yes" ]; then
  if "${DRIVER}" pull "${NOW_ID}" "${WORK}/back" >/dev/null 2>&1; then
    ok "pulled the set back"
    miss=0
    for f in atrocore.dump alf_data.tar.gz MANIFEST; do
      if [ ! -f "${WORK}/back/${f}" ]; then no "missing after pull: ${f}"; miss=1; fi
    done
    if [ "${miss}" -eq 0 ]; then
      bad=0
      for f in atrocore.dump alf_data.tar.gz MANIFEST; do
        a="$(sha256sum "${WORK}/src/${f}" | cut -d' ' -f1)"
        b="$(sha256sum "${WORK}/back/${f}" | cut -d' ' -f1)"
        [ "${a}" = "${b}" ] || { no "content differs after round trip: ${f}"; bad=1; }
      done
      [ "${bad}" -eq 0 ] && ok "every file is byte-identical after the round trip"
    fi
  else
    no "pull failed"
  fi

  # A set id that was never pushed must fail, not silently return nothing --
  # otherwise a restore from a mistyped id looks like an empty backup.
  if "${DRIVER}" pull "19700101T000000Z" "${WORK}/absent" >/dev/null 2>&1; then
    no "pulling a nonexistent set succeeded; it must fail"
  else
    ok "pulling a nonexistent set fails"
  fi
else
  info "fetch=no: skipping the round trip. This destination cannot be verified by reading it back,"
  info "which is a property of the storage, not a fault. Its assurance has to come from elsewhere."
fi

# ---------------------------------------------------------------------------
step "5. prune"
if [ "${PRUNE}" = "yes" ]; then
  make_set "${WORK}/old"
  if "${DRIVER}" push "${WORK}/old" "${OLD_ID}" >/dev/null 2>&1; then
    CREATED="${CREATED} ${OLD_ID}"
    n="$("${DRIVER}" prune 30 2>/dev/null | tail -1)"
    remaining="$("${DRIVER}" list 2>/dev/null)"
    if printf '%s\n' "${remaining}" | grep -qx "${OLD_ID}"; then
      no "prune left a set dated 1999 behind (reported ${n:-0} pruned)"
    else
      ok "prune removed the 1999 set (reported ${n:-0})"
    fi
    # The far-future id must survive: pruning by file mtime instead of by
    # set id would delete it, since it was written seconds ago.
    if printf '%s\n' "${remaining}" | grep -qx "${NOW_ID}"; then
      ok "prune kept the in-retention set"
    else
      no "prune deleted a set inside the retention window — is it dating by file mtime rather than set id?"
    fi
  else
    no "could not push the synthetic old set"
  fi
elif [ "${PRUNE}" = "self" ]; then
  info "prune=self: the destination expires sets itself, so nothing is pruned from here."
  info "Confirm the lifecycle rule exists and matches your retention policy — nothing in this repository can."
else
  info "prune=no: old sets must be removed by hand."
fi

# ---------------------------------------------------------------------------
step "6. clean up the synthetic sets"
if [ "${KEEP}" -eq 1 ]; then
  info "--keep given; leaving ${CREATED} behind"
elif [ "${PRUNE}" = "yes" ]; then
  "${DRIVER}" prune 0 >/dev/null 2>&1 || true
  left="$("${DRIVER}" list 2>/dev/null | grep -cx -e "${NOW_ID}" -e "${OLD_ID}" || true)"
  [ "${left}" = "0" ] && ok "synthetic sets removed" || no "synthetic sets are still there — remove them by hand"
else
  info "this driver cannot prune; remove ${CREATED} by hand"
fi

printf '\n'
if [ "${FAILED}" -eq 0 ]; then
  green "${PASSED} checks passed — '${DEST_NAME}' satisfies the destination contract."
  exit 0
fi
red "${FAILED} of $((PASSED + FAILED)) checks failed for '${DEST_NAME}'."
exit 1
