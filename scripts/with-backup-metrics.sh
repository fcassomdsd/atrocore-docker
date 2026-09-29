#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Run a backup job and record how it went, where Prometheus can see it.
#
#   scripts/with-backup-metrics.sh <job-name> <command> [args...]
#
# WHY THIS EXISTS
# ---------------
# A timer that stops firing is invisible. So is one that fires and fails
# every night. Both look exactly like a healthy system from the outside, and
# the first anyone learns of either is a restore that has nothing to restore
# from -- which is the same silent-failure shape as a WAL archiver that
# cannot write, and it deserves the same treatment: make it a metric and
# alert on it.
#
# node-exporter's textfile collector reads *.prom out of a directory and
# publishes whatever it finds. So each run leaves behind when it last
# started, when it last SUCCEEDED, how long it took and its exit code, and
# Prometheus alerts when the last success gets too old -- or when the metric
# is absent entirely, which is what a timer that was never enabled looks
# like.
#
#   BACKUP_METRICS_DIR   default /var/lib/node_exporter/textfile
#                        Unset or unwritable, the job still runs and this
#                        just does not record -- the backup matters more
#                        than the telemetry about it.

set -uo pipefail

JOB="${1:?usage: with-backup-metrics.sh <job-name> <command> [args...]}"; shift
[ $# -gt 0 ] || { echo "with-backup-metrics: no command given" >&2; exit 2; }

# The label is backup_job, not job. `job` is reserved: Prometheus sets it to
# the scrape job name and renames any colliding label on the metric to
# `exported_job`. Rules written against job="nightly" then match nothing and
# never fire -- alerting that looks configured and protects nothing, which is
# strictly worse than none. Found only by querying Prometheus end to end.
DIR="${BACKUP_METRICS_DIR:-/var/lib/node_exporter/textfile}"
OUT="${DIR}/oversight_backup_${JOB}.prom"

START="$(date -u +%s)"
"$@"
RC=$?
END="$(date -u +%s)"

if [ -d "${DIR}" ] && [ -w "${DIR}" ]; then
  # Written to a temporary file and moved into place: the textfile collector
  # may read at any moment, and a half-written .prom file makes it drop the
  # whole file -- so a scrape landing mid-write would erase the very metric
  # that says backups are healthy.
  TMP="$(mktemp "${OUT}.XXXXXX")"
  {
    echo "# HELP oversight_backup_last_run_timestamp_seconds When this backup job last started."
    echo "# TYPE oversight_backup_last_run_timestamp_seconds gauge"
    echo "oversight_backup_last_run_timestamp_seconds{backup_job=\"${JOB}\"} ${START}"
    echo "# HELP oversight_backup_last_duration_seconds How long the last run took."
    echo "# TYPE oversight_backup_last_duration_seconds gauge"
    echo "oversight_backup_last_duration_seconds{backup_job=\"${JOB}\"} $((END - START))"
    echo "# HELP oversight_backup_last_exit_code The last run's exit status. 0 is success."
    echo "# TYPE oversight_backup_last_exit_code gauge"
    echo "oversight_backup_last_exit_code{backup_job=\"${JOB}\"} ${RC}"
    echo "# HELP oversight_backup_last_success_timestamp_seconds When this job last SUCCEEDED."
    echo "# TYPE oversight_backup_last_success_timestamp_seconds gauge"
    if [ "${RC}" -eq 0 ]; then
      echo "oversight_backup_last_success_timestamp_seconds{backup_job=\"${JOB}\"} ${END}"
    else
      # Carry the previous success forward rather than dropping it. Without
      # this a single failure erases the series, and "no data" reads as "no
      # backups have ever run" -- a different and much louder problem than
      # the one that actually happened.
      prev="$(sed -n "s/^oversight_backup_last_success_timestamp_seconds{backup_job=\"${JOB}\"} //p" "${OUT}" 2>/dev/null | tail -1)"
      echo "oversight_backup_last_success_timestamp_seconds{backup_job=\"${JOB}\"} ${prev:-0}"
    fi
  } > "${TMP}"
  chmod 0644 "${TMP}"
  mv -f "${TMP}" "${OUT}"
else
  echo "with-backup-metrics: ${DIR} is not writable; not recording metrics for '${JOB}'" >&2
fi

exit "${RC}"
