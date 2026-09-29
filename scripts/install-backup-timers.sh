#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Render and install the backup systemd units for this checkout.
#
#   scripts/install-backup-timers.sh --print          # show what would be written
#   scripts/install-backup-timers.sh --user           # install as user units (testing)
#   sudo scripts/install-backup-timers.sh --system    # install system-wide
#
#   --repo <dir>       default: this checkout
#   --env-file <path>  default: /etc/compliance-platform/backup.env
#                      (--user default: ~/.config/compliance-platform/backup.env)
#
# The units ship with a placeholder installation path because systemd has no
# notion of "the directory this unit came from". Editing six files by hand is
# how one of them ends up pointing at the wrong checkout, so this does the
# substitution.
#
# --user exists so the schedule can be exercised without root, which is the
# only way to find out whether a timer actually fires before trusting it with
# the backups. A real deployment uses --system.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_DIR}/deploy/systemd"
MODE=""
REPO="${REPO_DIR}"
ENVFILE=""
PLACEHOLDER="/opt/compliance-platform/atrocore-docker"
PLACEHOLDER_ENV="/etc/compliance-platform/backup.env"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --print)    MODE=print; shift ;;
    --user)     MODE=user; shift ;;
    --system)   MODE=system; shift ;;
    --repo)     REPO="${2:?--repo needs a directory}"; shift 2 ;;
    --env-file) ENVFILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help)  sed -n '4,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done
[ -n "${MODE}" ] || die "one of --print, --user or --system is required"

case "${MODE}" in
  user)   TARGET="${HOME}/.config/systemd/user"; : "${ENVFILE:=${HOME}/.config/compliance-platform/backup.env}" ;;
  system) TARGET="/etc/systemd/system";          : "${ENVFILE:=${PLACEHOLDER_ENV}}" ;;
  print)  TARGET="(not written)";                : "${ENVFILE:=${PLACEHOLDER_ENV}}" ;;
esac

UNITS=(
  compliance-backup.service compliance-backup.timer
  compliance-wal-ship.service compliance-wal-ship.timer
  compliance-backup-verify.service compliance-backup-verify.timer
)

render() { # render <unit> -> rendered text on stdout
  sed -e "s#${PLACEHOLDER}#${REPO}#g" -e "s#${PLACEHOLDER_ENV}#${ENVFILE}#g" "${SRC}/$1" \
    | if [ "${MODE}" = "user" ]; then
        # docker.service is a SYSTEM unit and the user manager cannot see it:
        # a user unit ordering itself After= it fails to start outright with
        # "Unit docker.service not found". The ordering is correct and stays
        # for a real --system install; it is only meaningless here, where
        # Docker is already running before anyone logs in.
        sed -e 's/^\(After=.*docker\.service.*\)$/# [--user] \1/' \
            -e 's/^\(Wants=.*docker\.service.*\)$/# [--user] \1/' \
            -e 's/^\(Requires=.*docker\.service.*\)$/# [--user] \1/'
      else
        cat
      fi
}

if [ "${MODE}" = "print" ]; then
  for u in "${UNITS[@]}"; do
    printf '\n----- %s -----\n' "${u}"
    render "${u}"
  done
  exit 0
fi

# A unit whose ExecStart does not exist installs happily and fails at the
# first firing -- typically at 01:30, unattended, into a journal nobody is
# reading. Check now instead.
for s in with-backup-metrics.sh backup-nightly.sh ship-wal-archive.sh backup-offsite.sh; do
  [ -x "${REPO}/scripts/${s}" ] || die "missing or not executable: ${REPO}/scripts/${s}"
done

[ -f "${ENVFILE}" ] || printf '\033[33m  !! %s does not exist yet — the units will fail until it does.\n     Start from deploy/systemd/backup.env.example\033[0m\n' "${ENVFILE}"

mkdir -p "${TARGET}"
for u in "${UNITS[@]}"; do
  render "${u}" > "${TARGET}/${u}"
  printf '    wrote %s\n' "${TARGET}/${u}"
done

if [ "${MODE}" = "user" ]; then
  systemctl --user daemon-reload
  green "Installed as user units. Enable with:"
  echo "    systemctl --user enable --now compliance-backup.timer compliance-wal-ship.timer compliance-backup-verify.timer"
  echo "    systemctl --user list-timers 'compliance-*'"
  echo
  echo "  User units stop when you log out unless lingering is on:"
  echo "    loginctl enable-linger $(id -un)"
else
  systemctl daemon-reload
  green "Installed. Enable with:"
  echo "    systemctl enable --now compliance-backup.timer compliance-wal-ship.timer compliance-backup-verify.timer"
  echo "    systemctl list-timers 'compliance-*'"
fi
