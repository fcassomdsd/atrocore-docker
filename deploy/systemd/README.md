# Scheduling the backups

Three timers. Without them the scripts in `scripts/` are things somebody has
to remember, and a backup somebody has to remember is a backup that stops
happening the first busy week.

| Unit | When | What |
|---|---|---|
| `compliance-backup.timer` | nightly 02:30 | take a set, push it offsite, expire old sets |
| `compliance-wal-ship.timer` | every 15 min | ship archived WAL offsite |
| `compliance-backup-verify.timer` | Sunday 04:00 | read the newest offsite set back and re-check every checksum |

## Install

```bash
install -d -m 0750 /etc/compliance-platform
cp deploy/systemd/backup.env.example /etc/compliance-platform/backup.env
chmod 0600 /etc/compliance-platform/backup.env
$EDITOR /etc/compliance-platform/backup.env          # destination + credentials

sudo scripts/install-backup-timers.sh --system
sudo systemctl enable --now compliance-backup.timer \
                             compliance-wal-ship.timer \
                             compliance-backup-verify.timer
systemctl list-timers 'compliance-*'
```

`install-backup-timers.sh` fills in the installation path, because systemd
has no notion of "the directory this unit came from" and editing six files
by hand is how one ends up pointing at the wrong checkout. `--print` shows
what it would write without writing it.

Credentials live in the `EnvironmentFile`, never in the units: the units are
tracked in git, and a credential in a tracked file is a published one.

### Trying it without root

```bash
scripts/install-backup-timers.sh --user
systemctl --user start compliance-wal-ship.service
journalctl --user -u compliance-wal-ship.service -n 50
```

Use a scratch `BACKUP_DIR` and destination. The installer comments out the
`docker.service` ordering for user units — that is a system unit the user
manager cannot see, and a user unit referring to it refuses to start.

## Knowing they still run

This is the part that matters. A timer that stops firing looks exactly like
a healthy system, and so does one that fires and fails every night. Both are
only discovered by someone needing a restore.

So every run records its outcome as a Prometheus metric, via node-exporter's
textfile collector:

```
oversight_backup_last_run_timestamp_seconds{backup_job="nightly"}
oversight_backup_last_success_timestamp_seconds{backup_job="nightly"}
oversight_backup_last_duration_seconds{backup_job="nightly"}
oversight_backup_last_exit_code{backup_job="nightly"}
```

`BACKUP_METRICS_DIR` must be the directory node-exporter reads — the
observability stack mounts it from the same variable, so set it in both
places or the metrics are written and never seen.

> The label is `backup_job`, not `job`. `job` is reserved: Prometheus sets it
> to the scrape job name and renames a colliding metric label to
> `exported_job`. Rules written against `job="nightly"` match nothing and
> never fire — alerting that looks configured and protects nothing.

Five alerts in `observability/prometheus/rules/platform-alerts.yml` use
these. The one to understand is **`BackupNeverRan`**, which fires on
`absent()`: a timer nobody enabled produces no metric at all, and every
threshold rule reads that as "fine". It is the rule that catches a backup
system that was never switched on.

A failed run deliberately carries the previous success timestamp forward
rather than dropping the series — otherwise one failure erases the history
and "no data" reads as "no backups have ever run", a different and much
louder problem than the one that actually happened.

## Ordering, and why prune is last

`backup-nightly.sh` runs the sequence in one script rather than chaining
three units: chaining spreads one sequence across three unit files and three
journal entries, and "did step two run?" becomes something you infer.

Prune runs **last, and only after a successful push**. Expiring old sets
before the new one is safely offsite would, on a bad night, leave fewer
backups than it started with.
