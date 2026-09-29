#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Check that the backup MANIFEST is parsed correctly wherever it is read.
#
#   sh scripts/verify-manifest-parsing.sh
#
# WHY THIS EXISTS
# ---------------
# A backup MANIFEST contains TWO `- name:` lists. `files:` names the files in
# the set, each with a sha256. `wal_archives:` names archive DIRECTORIES,
# which are not in the set at all and have no checksum.
#
# Both restore-platform.sh and backup-offsite.sh verify a set by walking that
# manifest, and both originally matched `- name:` with a line-oriented sed --
# which cannot distinguish the two lists. They therefore read the three WAL
# archive labels as files, found them missing, and refused the set:
#
#     FAIL atrocore listed in MANIFEST but missing
#     3 file(s) failed verification — refusing to restore a corrupt set
#
# That made restore-platform.sh unable to restore ANY set taken after WAL
# archiving was added, and nothing noticed, because no test ever fed it a
# manifest with a wal_archives block. This is that test.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$(mktemp -d)
PASSED=0; FAILED=0
trap 'rm -rf "$WORK"' EXIT INT TERM

ok() { PASSED=$((PASSED+1)); printf '  ok   %s\n' "$1"; }
no() { FAILED=$((FAILED+1)); printf '\033[31m  FAIL %s\033[0m\n' "$1" >&2; }

# A manifest in the shape backup-platform.sh actually writes, including the
# wal_archives block that caused the bug.
cat > "$WORK/MANIFEST" <<'EOF'
# compliance-platform backup set
created_utc: 20260929T130352Z
host: example-host
wal_archives:
  - name: atrocore
    path: /srv/atrocore/wal-archive
    segments: 42
  - name: alfresco
    path: /srv/alfresco/wal-archive
    segments: 265
  - name: compliance_web
    path: /srv/web/wal-archive
    segments: 23
# PITR = the newest *.basebackup.tar in this set, plus WAL from the
# archive paths above.
files:
  - name: alf_data.tar.gz
    bytes: 491164568
    sha256: 810d0d54f902c282f94cc2d83e8e5df42c210ca94f896d869bf395871cbd10ec
  - name: alfresco.dump
    bytes: 1583194
    sha256: 8170e9233956e6c246c0f01c72dc4fa2e95dad41369e0811aae6438cc07e0866
  - name: compliance_web.basebackup.tar
    bytes: 49284096
    sha256: 28410a23782759fe07fe2e7a434a561148c0f4b8a552f58d2a1dacfd585a12b0
EOF

EXPECTED="alf_data.tar.gz
alfresco.dump
compliance_web.basebackup.tar"

printf '\nThe parser extracts files, and only files\n'
ACTUAL="$(awk '/^files:/ {infiles=1; next} /^[^ #]/ {infiles=0} infiles && /^  - name: / {sub(/^  - name: /, ""); print}' "$WORK/MANIFEST")"
if [ "$ACTUAL" = "$EXPECTED" ]; then
  ok "three files, in order"
else
  no "parser returned:
$ACTUAL
expected:
$EXPECTED"
fi

for label in atrocore alfresco compliance_web; do
  if printf '%s\n' "$ACTUAL" | grep -qx "$label"; then
    no "a wal_archives label leaked into the file list: $label"
  else
    ok "wal_archives label excluded: $label"
  fi
done

printf '\nThe old parser is gone from every script that reads a MANIFEST\n'
# The exact expression that caused the bug. Its reappearance anywhere is the
# regression, whatever else the script looks like.
for f in restore-platform.sh backup-offsite.sh; do
  if grep -q "sed -n 's/\^  - name: //p'" "$SCRIPT_DIR/$f" 2>/dev/null; then
    no "$f still uses the line-oriented parser that cannot tell the two lists apart"
  else
    ok "$f does not use the old parser"
  fi
done

printf '\nBoth scripts parse identically\n'
# Two copies of the parser is a drift risk; if they disagree, one of them is
# wrong and nobody finds out until a restore.
a="$(grep -o "awk '/\^files:/.*print}'" "$SCRIPT_DIR/restore-platform.sh" | head -1)"
b="$(grep -o "awk '/\^files:/.*print}'" "$SCRIPT_DIR/backup-offsite.sh" | head -1)"
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  ok "restore-platform.sh and backup-offsite.sh use the same expression"
else
  no "the two parsers differ:
  restore-platform.sh: ${a:-<not found>}
  backup-offsite.sh:   ${b:-<not found>}"
fi

printf '\nA manifest with no wal_archives block still works\n'
sed '/^wal_archives:/,/^# PITR/d' "$WORK/MANIFEST" > "$WORK/M2"
n="$(awk '/^files:/ {infiles=1; next} /^[^ #]/ {infiles=0} infiles && /^  - name: / {print}' "$WORK/M2" | grep -c .)"
[ "$n" = "3" ] && ok "older manifests parse unchanged" || no "expected 3 files from a wal-less manifest, got $n"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
