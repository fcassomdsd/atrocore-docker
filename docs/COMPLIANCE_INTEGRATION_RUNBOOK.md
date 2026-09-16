# Compliance Integration Runbook

This runbook describes how to bring up and validate the integrated compliance platform across:

- `atrocore-docker` (foundational AtroCore backend)
- `compliance_cmis` (Alfresco + custom CMIS web scripts)
- `compliance_import` (ZIP ingestion service)
- `compliance_flow` (Node-RED middleware)
- `compliance_web` (web UI + auth/session backend)
- `compliance_checklist` (offline Electron field app)

## 1. Purpose and Scope

Use this runbook to:

- start the stack in the correct order
- verify network connectivity and endpoint readiness
- run a minimal cross-system smoke test
- identify where failures likely belong
- go from a clean clone to a demonstrable system (§7)

### 1.1 Repository layout and host prerequisites

The six repositories are **independent clones that must sit side by side** under one
directory. Several scripts reach into their siblings by relative path, so the layout is
load-bearing rather than cosmetic — `atrocore-docker/scripts/demo-quickstart.sh`, for
example, reads `../compliance_flow/.env` and `../compliance_import/example data/`, and
`compliance_cmis/scripts/seed-demo-identities.sh` falls back to `../compliance_flow/.env`:

    <workspace>/
    ├── atrocore-docker/       # run the integration scripts from here
    ├── compliance_cmis/
    ├── compliance_flow/
    ├── compliance_import/
    ├── compliance_web/
    └── compliance_checklist/

Run the commands in this document from the repository directory they name.

Host requirements beyond Docker:

- Docker Engine with Compose v2 (`docker compose …`)
- `bash` and `curl` — every script and every check below uses them
- `node` — `scripts/demo-quickstart.sh` parses JSON responses with it, and the
  `compliance_flow` smoke harnesses are Node scripts
- `jq` — only for the by-hand recipes that pipe a response (e.g. §7.4's ticket); the
  quickstart script uses `node` instead
- `python3` — `scripts/install-metadata.sh` registers entity tabs with it, and the quickstart
  stamps the demo payloads with the seeded site visit's window through it
  (`compliance_import/scripts/stamp-payload-window.py`)

Assumed host OS: Linux.

## 2. High-Level Dependency Order

Start services in this order:

1. AtroCore backend (`atrocore-docker`)
2. Alfresco/CMIS backend (`compliance_cmis`)
3. Import service (`compliance_import`)
4. Node-RED middleware (`compliance_flow`)
5. Web app backend/frontend (`compliance_web`, optional for API-only tests)
6. Checklist desktop app (`compliance_checklist`, optional for API-only tests)

Why this order:

- Node-RED depends on external Docker networks and reachable AtroCore/Alfresco/import targets.
- Import service needs reachable Alfresco.
- Client apps depend on middleware/backend endpoints being live.

## 3. One-Time Host Preparation

### 3.1 Create shared Docker networks

Run once on the Docker host:

    docker network create backend_net || true
    docker network create alfresco_backend || true
    docker network create import-backend || true

### 3.2 Verify expected network names exist

    docker network ls | grep -E "backend_net|alfresco_backend|import-backend"

Expected result: all three names are present.

## 4. Environment Files and Secrets

### 4.1 AtroCore (`atrocore-docker`)

    cd atrocore-docker
    cp .env.example .env

Set at minimum:

- `POSTGRES_PASSWORD`
- `POSTGRES_PIM_USER`
- `POSTGRES_PIM_PASSWORD`
- `POSTGRES_PIM_DB`

Validate compose:

    docker compose config >/dev/null && echo "atrocore compose valid"

### 4.2 CMIS (`compliance_cmis`)

    cd ../compliance_cmis
    cp .env.example .env

Set non-default secrets for any non-local usage:

- DB password
- Solr secret
- keystore credentials

### 4.3 Import service (`compliance_import`)

    cd ../compliance_import
    cp .env.docker.example .env
    cp docker/secrets/alfresco_username.txt.example docker/secrets/alfresco_username.txt
    cp docker/secrets/alfresco_password.txt.example docker/secrets/alfresco_password.txt

Edit files with real credentials.

### 4.4 Node-RED middleware (`compliance_flow`)

    cd ../compliance_flow
    cp .env.example .env

Set at minimum:

- `ADMIN_PASSWORD_HASH`
- optional `API_KEY` for endpoint protection
- `NODE_RED_CREDENTIAL_SECRET`
- AtroCore and Alfresco credentials if you are not forwarding user tickets

### 4.5 Compliance Web (`compliance_web`)

    cd ../compliance_web
    cp .env.example .env

Set at minimum:

- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `ALFRESCO_BASE_URL` (default points to `http://proxy:8080` in compose)
- `AUTH_TICKET_ENCRYPTION_KEY`

## 5. Startup Procedure

### 5.1 Start AtroCore

    cd ../atrocore-docker
    docker compose up -d --build
    docker compose ps

Quick check:

    curl -f http://localhost || echo "AtroCore web not ready yet"

**Then install the application, then its metadata — neither is optional on a clean clone.**
`./web-data` is bind-mounted over `/var/www/`, and a bind mount does not inherit the
image's contents, so the AtroCore app that `prepare-pim.sh` installed during the build is
invisible. `install-atrocore.sh` bootstraps the files out of the image and then completes
AtroCore's own installation — the scaffold is not the installation: without it
`'isInstalled' => false`, the `user` table is empty, `/api/v1/App/user` answers `500` and
every consumer sees a broken AtroCore. `install-metadata.sh` then copies the tracked model
and the schema is created:

    ./scripts/install-atrocore.sh --yes    # bootstrap web-data/ + install (rebuilds the DB)
    ./scripts/install-metadata.sh          # copy the tracked model into web-data/
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run

Without this, `http://localhost` has no DocumentRoot, the API answers `500`, and every seed
fails on missing tables. §7.2 repeats it in the demo context.

Console commands must run as **`www-data`** (`-u www-data`). `docker compose exec` defaults
to root, and root-owned files in `data/cache` make the web process fail on its next cache
write — a `500` on every API route, with nothing in the Apache log to explain it.

### 5.2 Start CMIS/Alfresco

    cd ../compliance_cmis
    docker compose up -d
    docker compose ps

Readiness check:

    curl -f http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-

### 5.3 Start Import service

    cd ../compliance_import
    docker compose up -d --build
    docker compose ps

Health check:

    curl -f http://localhost:8000/health

### 5.4 Start Node-RED middleware

    cd ../compliance_flow
    docker compose up -d
    docker compose ps

Basic endpoint check (example):

    curl -i http://localhost:1880/specialties

If `API_KEY` is configured:

    curl -i -H "X-API-Key: <your-key>" http://localhost:1880/specialties

### 5.5 Start Compliance Web (optional)

The base compose file **publishes no ports**, and the UI service only exists under the
`dev` profile. You need both the dev override (for the `:4000` auth backend) and the
profile (for the `:3000` Vite UI):

    cd ../compliance_web
    docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up -d --build
    docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev ps

Check frontend and backend path:

    curl -f http://localhost:3000 || echo "frontend-dev not ready"
    curl -i http://localhost:4000/api/auth/diagnostics

`docs/shared/operations/DOCKER_SETUP.md` is the canonical guide for both profiles (the
`prod` profile runs nginx and proxies `/api/`, and is selected with `--profile prod`).

Either half alone is a trap: `--profile dev` without the override leaves `:4000`
unpublished (so the second `curl` above fails), and the override without the profile
starts the backend but no UI.

## 6. Core Smoke Test Matrix (15-Minute Pass)

Run in order and stop at first hard failure.

### 6.1 CMIS endpoint smoke

    curl -u admin:admin -X POST \
      -H "Content-Type: application/json" \
      --data @example/get-open-findings.sample.json \
      "http://localhost:8080/alfresco/s/api/findings/open/query"

Expected: JSON response with findings query output (possibly empty list, but valid structure).

### 6.2 Import service health and upload contract

Health:

    curl -f http://localhost:8000/health

Inspection import (replace with a real sample zip path):

    curl -X POST "http://localhost:8000/inspection-import" \
      -F "file=@/absolute/path/to/inspection_payload.zip"

Expected: JSON includes `status: imported` and counts.

### 6.3 Node-RED checklist retrieval

    curl -i http://localhost:1880/checklist

Expected: HTTP 200 and checklist payload for valid query parameters.

### 6.4 Node-RED findings proxy to Alfresco

    curl -i http://localhost:1880/findings/open

Expected: HTTP 200 with findings list; verifies middleware to CMIS path.

### 6.5 Web auth diagnostics (if web stack started)

    curl -i http://localhost:4000/api/auth/diagnostics

Expected: health-like auth/session diagnostics output.

## 7. Demo Quickstart — clean clone to a demonstrable system

Verified end to end on 2026-09-15 against the running stack. This is the concrete version
of the generic flow below it: every command here has been executed, and the intermediate
results quoted are the ones actually observed. Prerequisites are §3 (shared networks),
§4 (the `.env` files — four in practice; `compliance_cmis` runs on its defaults), the
side-by-side layout in §1.1, and a stack started per §5 (which includes §5.1's
application/metadata install).

The demo dataset is synthetic and additive — every row it writes has a `demo-` id, so it
can be removed with `seed-demo-dataset.sh --remove` without touching other records. The
airport is ICAO `ZZZZ` (ICAO's own "unknown aerodrome" placeholder), which makes every
generated document code (`V-ZZZZ-<year>-01`, `AV-ZZZZ-A-0001`) obviously synthetic.

The executable form of this section is `scripts/demo-quickstart.sh` in this repository:
run it from the repository root with `--yes` once the stack is up, and it performs §7.2's
app bootstrap, metadata install and seeding, §7.3 (identities), §7.4 and §7.6 in one pass,
then prints the closure-review calls for §7.5. Step 0b is what makes a clean clone work:
it bootstraps `web-data/` when it is empty, installs the tracked model and syncs the schema,
so no dump is needed. Read on when something fails — §7.7 lists the traps.

### 7.1 Start the stack

**One preparation step first, on a fresh checkout.** `compliance_cmis` writes its content store
into `./data/alf_data`, a bind mount that is gitignored — so a clone has no such directory,
Docker creates it `root:root 0755`, and the container (uid 33000) cannot create
`contentstore.deleted` inside it. Alfresco's `FileContentStore` then fails
(`Failed to create store root: ./alf_data/contentstore.deleted`), the `/alfresco` webapp never
deploys, and the container reports `unhealthy` — which reads like a model or database fault.
One command creates it with the ownership the container needs:

    cd compliance_cmis && ./scripts/bootstrap-alf-data.sh

Per §5, with one trap: **`compliance_web`'s base compose file publishes no ports.** The dev
override is what exposes the auth backend on `:4000`, and the `dev` profile is what starts
the UI on `:3000` — a full demo needs both:

    cd compliance_web
    docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up -d --build   # dev (API + UI)
    docker compose --profile prod up --build                                                     # prod (nginx proxies /api/)

Without the override the backend is healthy and listening *inside* the container but
unreachable from the host, so every `localhost:4000` call fails with a connection error
rather than an HTTP status; without the profile there is no UI. `docs/shared/operations/DOCKER_SETUP.md`
is the canonical guide for both profiles.

### 7.2 Install the application, the metadata and the demo data (`atrocore-docker`)

    ./scripts/install-atrocore.sh --yes          # bootstrap web-data/ + AtroCore's own install
    ./scripts/install-metadata.sh                # copy the tracked model into web-data/
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
    ./scripts/seed-usoap-vocabularies.sh --yes   # required: the enums the catalog points at
    ./scripts/seed-nomenclatura.sh --yes         # spec_* / atype_* reference rows
    ./scripts/seed-demo-dataset.sh --yes         # the demo dataset
    # or: make bootstrap / make metadata-install / make db-seed-vocabularies YES=1 …

On a **clean clone the first command is doing two jobs.** `./web-data` is bind-mounted over
`/var/www/`, and a bind mount does not inherit the image's contents, so the AtroCore app
installed at image-build time is hidden: `atro-web` serves nothing and this script used to
abort with "start the stack first so AtroCore creates web-data/", which the stack cannot do.
`install-metadata.sh` now detects the missing `web-data/<domain>/` and calls
`scripts/bootstrap-web-data.sh`, which copies the app out of the image; `sql diff --run`
then creates the schema. Run `make bootstrap` (or the script directly) if you want that step
on its own.

> **A clean clone needs no dump.** The whole operational model is tracked (all 32 entities with
> their `clientDefs`, `scopes` and `layouts`), so `install-metadata.sh` + `sql diff --run` above
> create every table the demo writes to — `location`, `service_provider`, `site_visit`,
> `service_area`, `finding`, the `CorrectiveAction*` family and the rest. Verified end to end on
> an isolated fresh instance with empty `web-data`/`db-data`: all three seeds below pass. A
> provisioned `atrocore.dump` is still how you load a **real authority's data** (README,
> "Restoring a real dataset") — it is deliberately not committed — but the schema no longer
> depends on it.

`seed-usoap-vocabularies.sh` is not optional and not demo data: the tracked entity
definitions reference the risk-level and USOAP extensible enums by hard-coded id, and
AtroCore's extensible enums have no home in `metadata/`. Without it a fresh install
resolves every risk level and USOAP Critical Element / area to nothing.

Result: **90 rows across 25 tables** — one fictional airport, two service providers, three
inspectors, **two site visits**, three inspections, the interview schedules the plan generator
needs, a checklist catalog (three topics, nine questions) with its USOAP citation chain, and the
per-inspection selections `/checklist` actually reads.

**The two visits exist because the demo walks two halves of the lifecycle that cannot share a
date** (§7.4 — the payload dates are derived from the visit the inspection belongs to):

| Visit | Dates | Status | Used for |
|---|---|---|---|
| `V-ZZZZ-2026-01` (`demo-sv-01`) | `CURRENT_DATE - 30` → `-29` | `Complete` | the ATS and MET inspections, whose checklists and findings are imported and whose finding is walked through closure — so a closure is reviewed *after* the finding was issued |
| `V-ZZZZ-2026-02` (`demo-sv-02`) | `CURRENT_DATE + 21` → `+22` | `Planned` | the planning walkthrough: `GET /inspectionPlan` on `demo-iprov-ans-02` renders the plan and moves `AV-ZZZZ-A-0002` from `Assigned` to `Planned` |

Both visits are re-dated relative to the day the seed runs, so the demo is coherent whenever it
is seeded — that is why the quickstart reads the window back from `demo-sv-01` and stamps the
payload dates with it rather than embedding dates in the ZIPs.

### 7.3 Demo identities (`compliance_cmis`)

One command, idempotent:

    cd compliance_cmis
    ./scripts/seed-demo-identities.sh --yes     # --remove deletes them again

It creates the `U-VSO-IN_ClosureReviewer` and `U-VSO-IN_Inspector` groups, the users
`closure.reviewer` and `demo.inspector1` — the latter matching `external_user_i_d` on the
demo inspector record, which is how an Alfresco login is linked to an inspector — their
group memberships, and repository access on `vigilancia-de-la-so`. The `closure_reviewer`
**role** comes from migration `0002_closure_reviewer_role.sql`, so **a new migration needs
a rebuilt image**: migrations are `COPY`d into `Dockerfile.backend`, and `docker compose up`
alone re-runs the old ones.

**The two passwords** are printed by the seed's closing banner, and they are the script's
`REVIEWER_PASSWORD` / `INSPECTOR_PASSWORD` variables — export either before running it to set
your own. They are demo-only credentials for a synthetic dataset (`closure.reviewer`,
`demo.inspector1`), committed so the walkthrough works out of the box: **change or delete them
on any deployment that is not a throwaway demo** (`./scripts/seed-demo-identities.sh --remove`),
exactly as §10 says for every other development default.

Two things here are easy to miss and both cost a round trip:

- **An application role does not grant an Alfresco permission.** The server authorises by
  role but performs the repository call with the user's own ticket, so an account that has
  a role and no repository access passes the role gate and then fails the write with `403`
  from Alfresco — which surfaces as `502` from the API.
- Repository access is granted at **site and folder level in Share**, and a *group* can hold it:
  `GROUP_U-VSO-IN_Inspector` is a **SiteConsumer** of `vigilancia-de-la-so` with **Contributor** on
  `Datos de campo` and `Hallazgos` — the two folders the ingestion path writes to. That is the
  pattern to follow: Consumer at the site, Contributor only where the role must write.
- The identity seed grants access **per user** because no *API* path for a group-level grant works
  in this deployment: the v1 site-members endpoint returns `404` for a group id (it accepts a
  person, `201`), the v1 node-permissions API returns `404` for `/nodes/{id}/permissions`, and the
  legacy `/alfresco/service/api/sites/{site}/memberships` webscript returns `500` for a `groupId`
  — and `400 "person or group has not been set"` when the body is JSON rather than form-encoded.
  Until the reviewer group is granted in Share, `seed-demo-identities.sh` gives each demo user
  membership directly, which is broader than the folder-scoped group grant above. Tracked in
  `TECHNICAL_DEBT_ANALYSIS.md`.

### 7.4 Populate the work products (`compliance_import` + `compliance_cmis`)

Both import endpoints require an operator ticket, and the canonical import takes
`?alf_ticket=`:

    TICKET=$(curl -s -X POST \
      "http://localhost:8080/alfresco/api/-default-/public/authentication/versions/1/tickets" \
      -H 'Content-Type: application/json' \
      -d "{\"userId\":\"$ALFRESCO_USERNAME\",\"password\":\"$ALFRESCO_PASSWORD\"}" | jq -r .entry.id)

**Stamp the payloads with the seeded window first.** The seed dates the site visit relative to
the day it runs (`CURRENT_DATE + 21`/`+ 22`, §7.3), while the ZIPs committed to
`compliance_import` freeze their dates the day they are written — and the payload's window is
what the canonical import copies onto the Alfresco inspection folder, so importing a stale ZIP
dates the inspection into the wrong week. The quickstart does this for you; by hand it is one
step per payload, with the window read back from the seed:

    # the window the seed computed for demo-sv-01
    WINDOW=$(docker compose exec -T db psql -U "$POSTGRES_PIM_USER" -d "$POSTGRES_PIM_DB" -tAc \
      "select to_char(start_date,'YYYY-MM-DD') || ' ' || to_char(end_date,'YYYY-MM-DD')
         from public.site_visit where id = 'demo-sv-01'")
    python3 ../compliance_import/scripts/stamp-payload-window.py \
      "../compliance_import/example data/demo_inspection_payload.zip" /tmp/demo_inspection_payload.zip \
      --start "${WINDOW%% *}" --end "${WINDOW##* }"

The tracked ZIP is never modified: the stamp writes a copy whose `checklist.startDate`/`endDate`
are the window's first/last day, shifts every other date by the same delta as the window's last
day (a finding issued on the inspection's last day stays there), and dates a follow-up payload's
`followUpDate` 13 days after the window ends (it belongs to an inspection in another ZIP, so it
has no window of its own). The commands below import the *stamped* copies — `/tmp/…` — rather
than the tracked files:

    # 1. the checklist + findings (bare-array findings.json, Evidence/ folder)
    curl -X POST http://127.0.0.1:8000/inspection-import -H "X-Alfresco-Ticket: $TICKET" \
      -F "file=@/tmp/demo_inspection_payload.zip"
    # => {"status":"imported","findingsImported":2,"evidenceImported":3}

    # 2. canonical import (the QUERY-PARAM form: no follow-up context, imports the documents)
    curl -X POST "http://localhost:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=$TICKET" \
      -H 'Content-Type: application/json' \
      -d '{"inspectionCode":"AV-ZZZZ-A-0001","specialtyName":"Servicio de tránsito aéreo"}'
    # => {"success":true,"summary":{"created":13,"findingsImported":2,...}}

    # 3. the follow-up (followup-reports.json + prior-findings.json + FollowUpEvidence/)
    curl -X POST http://127.0.0.1:8000/followup-import -H "X-Alfresco-Ticket: $TICKET" \
      -F "file=@/tmp/demo_followup_payload.zip"
    # => {"status":"imported","followUpReportsImported":1,"followUpEvidenceImported":1,
    #     "followUpFilenames":["FollowUp H-ZZZZA0001-ATS-001 01.json"]}

    # 4. process that follow-up: this is what moves the finding
    curl -X POST "http://localhost:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=$TICKET" \
      -H 'Content-Type: application/json' \
      -d '{"inspectionCode":"AV-ZZZZ-A-0001","specialtyName":"Servicio de tránsito aéreo",
           "followUpFiles":["FollowUp H-ZZZZA0001-ATS-001 01.json"]}'
    # => {"success":true,"summary":{"processed":1,"pendingClosureApprovals":1,...}}
    #    and the finding moves to "Pending Closure Approval"

**Two inspections, two payloads.** The dataset seeds an ATS inspection and a MET one, and each
needs its own payload for the same reason: the inspection **window** lives on the Alfresco
inspection folder (`vso:startDate`/`vso:endDate`; `inspection` in AtroCore has no date columns),
and that folder only exists once canonical documents have been imported for the inspection. A
seeded inspection with no payload cannot be dated, so its items drop out of the year-filtered
provider-history report. Run the same pair as steps 1 and 2 for MET:

    curl -X POST http://127.0.0.1:8000/inspection-import -H "X-Alfresco-Ticket: $TICKET" \
      -F "file=@/tmp/demo_met_inspection_payload.zip"
    # => {"status":"imported","inspectionId":"demo-insp-met-01","evidenceImported":3}

    curl -X POST "http://localhost:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=$TICKET" \
      -H 'Content-Type: application/json' \
      -d '{"inspectionCode":"AV-ZZZZ-I-0001","specialtyName":"Meteorología aeronáutica"}'

Step 6 below fails if either inspection ends up without a window, or with one that is not the
seeded site visit's.

**Step 4 is not optional and not the same as step 2.** The query-param form carries no
follow-up context, so `closurePolicy.shouldClose` never runs and the summary reports
`processed: 0, pendingClosureApprovals: 0` while the finding stays open. Only the
`followUpFiles` form processes a follow-up, and the filename is the one the follow-up
import reported in `followUpFilenames`.

A valid `Closure Verification` follow-up only makes a finding **eligible** for closure. It
never closes it. That is the two-step gate.

Known rough edge: re-processing a follow-up whose evidence has already been moved into the
finding folder fails with `404 Evidence source file not found`. Re-run step 3 first — the
payload re-supplies the evidence.

### 7.5 Walk the closure review (`compliance_web`)

Two ways to walk it: the browser, or the two curl calls below. The `closure_reviewer` role
was extended (2026-09-15) to read findings — list, detail, follow-ups and evidence content —
precisely so the browser path works; before that the role could decide a closure but got
`403 AUTH_FORBIDDEN` on every read, so only the curl path worked.

**Browser:** open http://localhost:3000 (see §5.5 for the command that publishes it), log in
as `closure.reviewer` with the password the identity seed printed (§7.3 — its
`REVIEWER_PASSWORD`, overridable), open **Findings**, and pick
`H-ZZZZA0001-ATS-001` (status `Pending Closure Approval`) to get the closure-review panel:
a reason field and Apply Decision, which is the `reject`/`approve` call below. The same
identity works as `demo.inspector1` (`INSPECTOR_PASSWORD`) if you want to see the inspector's
side of the finding.

**API:** login returns a `csrfToken` that must be sent as `X-CSRF-Token` with the session cookie:

    curl -c jar -X POST http://127.0.0.1:4000/api/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"username":"closure.reviewer","password":"<pw>"}'
    # => {"authenticated":true,"roles":["closure_reviewer"],"csrfToken":"..."}

    # reject: a reason is required, and is stored on the finding
    curl -b jar -X PATCH "http://127.0.0.1:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
      -d '{"decision":"reject","reason":"Closure evidence is undated"}'
    # => 200, finding back to "In Progress", vso:closureRejectionReason set and
    #    vso:findingClosureDate cleared (an open finding must not carry a closure date)

    # approve: closes it — but only while the finding is still Pending Closure Approval
    curl -b jar -X PATCH "http://127.0.0.1:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" -d '{"decision":"approve"}'
    # => 200, "Closed", vso:findingClosureDate set, rejection reason cleared

**Reject and approve are alternatives, not a sequence.** A rejection moves the finding back to
`In Progress`, and the next `approve` in that state answers `409 FINDING_NOT_REVIEWABLE`
("Only findings in Pending Closure Approval status can be reviewed"). To demonstrate the
approve path after a rejection, re-declare the closure first — re-run §7.4 steps 3 and 4 —
then approve.

The route requires the `closure_reviewer` role (`admin` is break-glass), refuses a reviewer
who is the recorded declarer (`403 CLOSURE_REVIEW_SELF`), and refuses a finding whose
declarer was never recorded (`409 CLOSURE_DECLARER_UNKNOWN`) rather than allowing an
unattributable approval.

### 7.6 Verify

    node compliance_flow/scripts/smoke-flows.mjs            # 15 passed, 0 failed, 10 skipped
    node compliance_flow/scripts/audit-error-envelope.mjs --enforce   # 5 pass, 0 fail
    curl "http://localhost:1880/findings/open?locationCode=ZZZZ&specialtyCode=ATS"
    # => 0 open once both demo findings are closed; each finding carries its status

`scripts/demo-quickstart.sh` also reads both inspection folders back and asserts each carries
exactly the seeded site visit's window (§7.4), because a checklist item is dated by its nearest
inspection ancestor and an item outside the period a report filters on simply disappears from it.

### 7.7 Traps encountered while building this (all cost a round trip)

- `compliance_web` base compose publishes no ports → use the dev override (§7.1).
- Dev image rebuilds need `COMPOSE_BAKE=false DOCKER_BUILDKIT=0` where buildx is absent;
  otherwise `docker compose build` fails on a read-only `~/.docker/buildx`.
- Migrations are baked into the backend image → rebuild for a new one (§7.3).
- The two `import-canonical` forms are not interchangeable (§7.4).
- Payload shapes: `findings.json` is a **bare array**; a follow-up ZIP needs
  `followup-reports.json` **and** `prior-findings.json` (both bare arrays) plus a
  `FollowUpEvidence/` folder — not `Evidence/`, which is the inspection-import folder name.
- Application role ≠ Alfresco permission (§7.3).
- **A bind mount hides the image's contents.** `./web-data:/var/www/` shadows the AtroCore
  app the image was built with, so a clean clone starts with an empty `/var/www`, no
  DocumentRoot, and a metadata install that fails with advice the stack cannot satisfy.
  `scripts/bootstrap-web-data.sh` (run for you by `install-metadata.sh`, or `make bootstrap`)
  copies the app out of the image; this was a named volume until commit `25affed`, which
  Docker *does* populate from the image. (§5.1, §7.2.)
- `/findings/open` is **search-backed** (AFTS/Solr), so it lags a few seconds behind a status
  change. Re-query before concluding a transition did not happen: the quickstart's final count read
  `0` immediately after a finding had moved to `Pending Closure Approval`, and `1` a moment later.

### 7.8 Generic lifecycle (for reference)

Where the demo's state actually lives, so any step can be traced to the system that owns it:

| What | System of record | How it moves |
|---|---|---|
| Site visit, inspection, inspector, specialty | **AtroCore** (`site_visit`, `inspection`, `inspector`, `specialty`) | Written by the seeds; read by Node-RED's `/siteVisits`, `/providers`, `/inspection/:id` |
| Plan and report | **Alfresco**, under `Vigilancia/Inspecciones/<inspectionCode>/` | `/inspectionPlan` and `/inspectionReport` render the `.fodt` templates and file the PDFs; the AtroCore `inspection.status` follows (`Planned`, `Reported`) |
| Checklist, findings, follow-ups, evidence | **Alfresco** canonical documents | `compliance_checklist` exports a ZIP → `/inspection-import` and `/followup-import` store it → `/importCanonical` builds the canonical model and moves the evidence |
| Inspection window (`vso:startDate`/`vso:endDate`) | **Alfresco inspection folder** — AtroCore's `inspection` has no date columns | Copied from the payload's `checklist.startDate`/`endDate` by the canonical import (§7.4) |
| Finding status, closure, CAP acceptance | **Alfresco** `vso:finding` properties | `compliance_web` writes them on the reviewer's decision; `vso:findingClosureDate` is set only when the finding reaches `Closed` |
| Sessions, roles, route authorisation | **PostgreSQL** (`compliance_web`) + Alfresco group membership | `alfresco_group_role_map` maps group → role; roles are cached in the session and refresh on login |

The per-provider `Inspection` status machine (`Created → Defined → Assigned → Planned → Uploaded → Reported → Complete`, with `Inactive` as a soft delete reachable only before `Uploaded`) is documented in `compliance_web/docs/STYLE_GUIDE.md` §12, and the finding/follow-up/CAP lifecycle in the platform `CLAUDE.md`; neither is restated here.

### 7.9 Generate the oversight artifacts (`compliance_flow` + `compliance_cmis`)

Step 7 of the quickstart does this automatically; by hand it is four calls. Two visits are
involved (§7.2): the **plan** belongs to the visit that has not happened yet, everything else to
the one that has.

    # plan — on the FUTURE visit, and it is also what moves the inspection Assigned -> Planned
    curl -s "http://localhost:1880/inspectionPlan?siteVisit=V-ZZZZ-$(date +%Y)-02&provider=demo-iprov-ans-02&locale=es"
    # => {"status":"success","generatedFile":{"name":"Plan de inspeccion - AV-ZZZZ-A-0002.pdf",
    #     "path":"…/Inspecciones/AV-ZZZZ-A-0002/…","version":"1.0","downloadURL":"…"},
    #     "inspectionFolder":"…","sourceName":"…","inspectionId":"demo-insp-ans-02","inspectionStatus":"Planned"}

    # inspection report — on the PAST visit, whose documents were imported in §7.4
    curl -s "http://localhost:1880/inspectionReport?siteVisit=V-ZZZZ-$(date +%Y)-01&provider=demo-prov-ans&locale=es"

    # provider history — the year filter is why a checklist item needs a dated inspection ancestor
    curl -s -X POST \
      "http://localhost:8080/alfresco/s/api/providers/provider-history-report?alf_ticket=$TICKET" \
      -H 'Content-Type: application/json' \
      -d "{\"providerId\":\"demo-prov-ans\",\"year\":\"$(date +%Y)\"}"
    # => {"success":true,…,"summary":{"total":26,…}}  — findings, checklist items and follow-ups

    # USOAP CE evidence — its artifacts are the chain tags the canonical import writes
    curl -s -X POST \
      "http://localhost:8080/alfresco/s/api/usoap/ce-evidence-report?alf_ticket=$TICKET" \
      -H 'Content-Type: application/json' \
      -d "{\"ce\":\"CE-5\",\"year\":\"$(date +%Y)\",\"populationQueries\":[{\"pqCode\":\"PQ 99.001\",\"artifactCategory\":\"Checklist\",\"specialtyCode\":\"ATS\",\"monthsBack\":24}]}"
    # => {"success":true,…,"summary":{"total":9,"byType":{"finding":2,"checklistItem":3,…},
    #     "byPq":{"PQ 99.001":…},"byArea":{"ATS":…},"gaps":[{"gap":"Missing evidence basis",…}]}}

**Watch the two parameter shapes — they are not the same.**

- `/inspectionPlan` takes the **inspected-provider** id (`demo-iprov-ans-02`) and reads its
  `serviceProviderId`; `/inspectionReport` takes the **service-provider** id (`demo-prov-ans`)
  and matches it with `siteVisitId`. Passing the wrong one answers `400` with a named error
  (`No inspected provider found for id: …`) instead of the `TypeError` it used to raise.
- The USOAP report needs an `artifactCategory` from its own vocabulary (`Checklist`,
  `InspectionReport`, `AuditReport`, `CAPExecution`, `TrainingRecord`, `PersonnelFile`, `Manual`,
  `License`, `OversightPlan`, `AerodromeDossier`); anything else comes back as a `population` gap
  naming the unknown category rather than as an error.

**The plan and the report are PDFs filed into the inspection folder** —
`Inspecciones/<inspectionCode>/` — not the `.fodt` sources the webscripts render, and each
response reports the PDF's path, version and download URL. The webscripts file them themselves
(transform, write, remove the source), so no repository-side rule is required; a deployment that
still has the old "fodt to odt" `Template data` rule does the same work first and the webscript's
own filing is simply not reached.

**Share smart folders** are the browser view of the same evidence (CE × area × evidence role),
auditor-facing navigation configured per provider profile: treat them as a Share walkthrough step
rather than a scripted one. The mapping and templates live in
`compliance_cmis/docs/smart-folders-operational-map.md` and `compliance_cmis/templates/`.

### 7.10 The field app (`compliance_checklist`)

The demo imports **pre-made ZIPs** (§7.4), which shows the ingestion contract but not the app that
produces them. To walk the field half:

    cd compliance_checklist
    npm install
    npm run build          # both `npm start` and e2e need a build first
    npm start              # the Electron app

`app.config.json` already points at this stack — `http://localhost:1880` for the flow (checklists,
findings, specialties, locations), `http://localhost:8000` for the ZIP upload and
`http://localhost:8080` for the sync-time Alfresco sign-in — so a local demo needs no
configuration. Worth knowing:

- **Operator login is required** (`identity.requireOperator`): sign in as `demo.inspector1` (§7.3)
  at sync time. The ticket is verified against Alfresco before an upload and is never stored.
- The app is **offline-first** and falls back to the bundled data in `app.config.json` when the
  flow is unreachable, so a responsive app is not evidence that the stack is up — check the
  service indicator.
- `npm run e2e` needs a built app **and** a display (`xvfb-run` on a headless host); CI installs
  both. Without a display it fails before it reaches the app.

## 8. Failure Isolation Guide

Use these quick cues:

- `localhost:8080` CMIS ready probe fails:
  - likely Alfresco stack boot/resource/config issue (`compliance_cmis`).
- `localhost:8000/health` fails while Alfresco is up:
  - likely import container or secret/env misconfiguration (`compliance_import`).
- Node-RED endpoint returns auth/network errors:
  - check external network attachment and upstream URLs in flows (`compliance_flow`).
- Web login/session errors:
  - verify PostgreSQL schema initialization and `AUTH_TICKET_ENCRYPTION_KEY` (`compliance_web`).
- API returns `502` whose message is an inner `403` from Alfresco:
  - the caller's *role* was authorized but the account has no **repository permission**;
    an application role does not grant an Alfresco ACL (§7.3).
- Web/API calls to `localhost:4000` fail with a connection error, not an HTTP status:
  - the backend is up but its port is unpublished; start it with the dev override (§7.1).

For logs:

    docker compose logs -f <service>

Run from each repository directory with the relevant service name.

## 9. Shutdown Procedure

Recommended order for clean stop:

1. `compliance_web`
2. `compliance_flow`
3. `compliance_import`
4. `compliance_cmis`
5. `atrocore-docker`

Command pattern:

    docker compose down

## 10. Operational Notes

- For production-like usage, replace all development defaults for credentials and secrets.
- Keep shared network names stable across all repos.
- Maintain one source of truth for endpoint/auth policy to avoid drift between web app, checklist app, and middleware.