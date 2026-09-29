#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# The nightly backup: take a set, put it offsite, expire what is old.
#
# One script rather than three chained systemd units. Chaining with
# OnSuccess= spreads a single sequence across three unit files and three
# journal entries, and the failure semantics ("did step two run?") become
# something you infer from logs rather than read. This is the sequence; the
# unit just calls it.
#
# Ordering is not arbitrary. Prune runs LAST and only after a successful
# push: expiring old sets before the new one is safely offsite would, on a
# bad night, leave fewer backups than it started with.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1" >&2; }
step()  { printf '\n=== %s\n' "$1"; }

step "1. Take a backup set"
if ! "${REPO_DIR}/scripts/backup-platform.sh" --yes; then
  red "backup-platform.sh failed — nothing to ship, and nothing will be pruned"
  exit 1
fi

if [ -z "${BACKUP_DESTINATION:-}" ]; then
  red "BACKUP_DESTINATION is not set: the set was taken but stays on this host."
  red "A backup that lives only on the machine it protects is the thing this is meant to fix."
  exit 1
fi

step "2. Push it offsite"
if ! "${REPO_DIR}/scripts/backup-offsite.sh" push; then
  red "offsite push failed — the local set is intact; NOT pruning"
  exit 1
fi

step "3. Expire old sets at the destination"
if ! "${REPO_DIR}/scripts/backup-offsite.sh" prune; then
  red "prune failed (the new set is safely offsite, so this is not urgent)"
  exit 1
fi

green "Nightly backup complete."
