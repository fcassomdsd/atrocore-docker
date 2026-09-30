# Observability

Prometheus, Alertmanager, Grafana and Loki for the compliance platform. **P3.5.**

This is a separate Compose project. It adds nothing to the six application
compose files and sits on nothing's startup path, because the lean demo has to
keep working from a clean clone and the surest way to guarantee that is for
monitoring to be something you start, not something that starts with the
platform.

```bash
cp observability/.env.example observability/.env   # set GRAFANA_ADMIN_PASSWORD and the DB passwords
docker compose -f observability/docker-compose.yaml up -d
```

| UI | URL | Auth |
|---|---|---|
| Grafana | http://127.0.0.1:3001 | `admin` / `GRAFANA_ADMIN_PASSWORD` |
| Prometheus | http://127.0.0.1:9090 | none |
| Alertmanager | http://127.0.0.1:9093 | none |
| MailPit (alert sink) | http://127.0.0.1:8025 | none |

All three bind to **loopback only** by default (`OBS_BIND_IP`). Prometheus has
no authentication of any kind and Alertmanager can silence alerts, so neither
belongs on a network. Reach them over a tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 <host>
```

---

## Why this exists, in one measurement

Stop ActiveMQ and look at what the platform says about itself:

```
Alfresco -ready- probe:                     200
probe http://proxy:8080/.../probes/-ready-  = 1
probe http://node-red:1880/health           = 1
probe http://backend:4000/health            = 1
probe http://compliance-import:8000/health  = 1
probe http://atro-web:80/health             = 1
probe http://share:8080/share               = 1
```

Every health endpoint on the platform is green, Alfresco's own readiness probe
included — and meanwhile, per `FOOTPRINT_AUDIT.md`, replanning an existing
document hangs forever with no error and nothing in any log to say why. That
output is real; it was captured while verifying this stack.

The one thing that noticed was the dedicated TCP probe of `activemq:61616`,
which fired `ActiveMQBrokerUnreachable` two minutes and sixteen seconds after
the broker stopped.

That is the gap this stack closes. Health endpoints answer "is this process
alive"; they are deliberately shallow, because a check that reaches a wedged
upstream inherits the wedge. Composing the whole-stack picture from outside is
this stack's job, not theirs.

---

## Proving it works

```bash
../scripts/verify-observability.sh
```

It stops a container on purpose, waits for the alert to reach `firing`,
confirms Alertmanager received it, **confirms the notification was actually
delivered**, restarts the container, waits for the alert to clear, and
confirms the recovery notice arrived too — failing if any step does not
happen. A Prometheus that is
running, a Grafana with a dashboard and alert rules that parse are all easy to
mistake for monitoring, and none of them shows that anything would be
*noticed*. Every failure this stack was built for is one where the system
looks fine, so "it looks fine" is the one piece of evidence that cannot be
trusted here.

```
=== PASS — a stopped container fired an alert, reached Alertmanager, was DELIVERED, and both it and its recovery notice arrived.
```

Until 2026-09-30 it stopped at "reached Alertmanager". That was the honest
limit at the time — with no mail server there was nothing to assert delivery
against — but it meant the drill passed while all 22 rules routed to a
receiver that notified nobody. Detection is the harder half and it was
working; the half that makes detection useful was missing and the drill could
not see it. If MailPit is not running the script says so and reports
`PASS (detection only)` rather than quietly narrowing what it proved.

`--target <container>` picks a different victim; `--keep-broken` leaves it
stopped so you can look at the alert by hand.

---

## What is watched

| Source | What for |
|---|---|
| blackbox-exporter (HTTP) | The `/health` endpoint of every service, probed from outside with a 5s timeout |
| blackbox-exporter (TCP) | ActiveMQ `:61616` and Solr `:8983` — the two measured silent failures |
| cAdvisor | Per-container CPU, and memory against each container's declared limit |
| node-exporter | Host filesystem free space |
| postgres-exporter ×3 | `pg_up`, connections, and above all WAL archiving state |
| Promtail → Loki | Every container's logs, with a severity label extracted |

Three of those choices are worth knowing about before changing them.

**ActiveMQ and Solr get TCP probes, not HTTP ones.** ActiveMQ's web console on
`:8161` can be perfectly healthy while the broker transport Alfresco actually
connects on is not. Solr sits behind Alfresco's shared-secret comms, so an
unauthenticated `GET /solr/admin/ping` answers `401` whether Solr is fine or
on fire — a check that reports the same thing in both states.

**The memory alert fires at 98%, not 90%.** `FOOTPRINT_AUDIT.md` measured
Alfresco idling at 95–97% of its cap in normal operation. A 90% rule would
fire on a healthy stack from the day it was deployed and be muted within a
week, and a muted rule is worse than no rule — it looks like coverage.

**WAL archiving is alerted on by backlog, not by age.** The obvious rule —
"`archive_timeout` is 300s, so nothing archived in an hour means something is
wrong" — is wrong, because `archive_timeout` does not force a segment switch
on a database that has written no WAL. Running it proved the point: all three
databases showed a last archive 5–9 hours old with a backlog of zero, which is
a healthy idle system. `pg_archiver_ready_count` only rises when there is
something to archive and it is not being archived.

Similarly, `pg_archiver_failing` asks whether the *last* attempt failed with
none succeeding since, not whether `failed_count > 0`. Those counters are
cumulative and survive restarts — Alfresco's database in the reference install
reads `failed_count=9, failing=0`, meaning it had a rough patch and recovered.
A count-based rule would have been red ever since, permanently.

---

## Alert delivery

There are two Alertmanager configs and `ALERTMANAGER_CONFIG` selects which one
is mounted:

| value | file | delivers to |
|---|---|---|
| *(default)* | `alertmanager/alertmanager.demo.yml` | the MailPit container in this project |
| `alertmanager.yml` | `alertmanager/alertmanager.yml` | whatever you configure — nothing, until you do |

**Why the demo one is the default.** The alternative default is what this
platform actually had: 22 alert rules, every one of them routed to a receiver
with no notifier. Alertmanager recorded and grouped them and the drill
confirmed they arrived, and nothing was ever sent to a person. Shipping a
default that delivers nowhere means the first time anyone finds out is during
an incident.

**MailPit is a test sink, not delivery.** It accepts any mail on port 1025,
keeps it in memory, and exposes it at <http://127.0.0.1:8025> over a UI and a
JSON API — which is what lets the drill *assert* delivery instead of asking
someone to go and look in an inbox. It is in the same compose project as the
thing it is monitoring, so it dies with the host it would be reporting on.
That is fine for a demo and unacceptable in production, and
`../scripts/preflight-secrets.sh --production` **fails** if this config is
still selected — the same treatment as the shared demo API key.

**For production**, set `ALERTMANAGER_CONFIG=alertmanager.yml` and fill that
file in. Note that **Alertmanager does not expand environment variables in its
configuration**, which is why there are no `${...}` placeholders in it: a
`${SMTP_HOST}` would be used as a literal hostname and the failure would
surface as mail quietly not arriving. Which *file* is mounted can be a
variable — compose expands the volume path — but its contents cannot be.
Use `auth_password_file` for the password: the file is tracked in git, and the
platform's rule since P3.1 is that a credential in a repository is a published
credential.

The production preflight also fails if the selected file configures no
notifier at all, so "I set the variable and forgot to fill the file in" is
caught rather than discovered later.

### A note on timing

`group_interval` is 5 minutes, and a group is flushed at most once per
interval — so a **resolved** notification cannot arrive sooner than that after
the firing one, no matter how fast the alert clears. The drill reads that
value from Alertmanager's own API rather than assuming it; the first version
waited 180 seconds and failed every time against a path that was working
perfectly.

---

## Cost, and the networks

Roughly **1 GiB of RAM** across twelve containers (MailPit adds ~30 MB), with per-container limits
in the compose file. `FOOTPRINT_AUDIT.md` puts the platform's own floor at 8 GB
minimum / 16 GB recommended; on an 8 GB host this stack is what pushes it over.
Run it on the 16 GB configuration, or accept that the demo host does not
monitor itself.

Every network in the compose file is `external: true`, created by one of the
six application projects — so **the platform starts first and this starts
second**, and starting it on a host where the applications have never run
fails with "network not found". There are six of them because the services
that have to be reached were never on one network: ActiveMQ, Solr, Share, the
transform engine and Alfresco's PostgreSQL live only on `compliance_cmis`'s own
project network, and two of those are the silent failures above.

Attaching here rather than asking five repos to join a monitoring network is
the deliberate trade: monitoring adapts to the platform, not the reverse.

**Stop this before tearing the platform down**, or `docker compose down` in an
application project leaves its network behind:

```
Network import-backend  Removing
Network import-backend  Resource is still in use
```

Verified, not assumed. It is harmless — the next `up` reuses the network —
but it looks like a failed teardown, and on a CI runner it leaves something
behind. `scripts/observability-verify-ci.sh --teardown` runs before the
platform teardown for this reason.

```bash
docker compose -f observability/docker-compose.yaml down
```
