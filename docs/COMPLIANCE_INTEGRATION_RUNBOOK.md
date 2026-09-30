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
`./web-data` is bind-mounted over `/var/www/`, and the `atro-web` image contains no AtroCore
application to shadow — it's installed directly into `web-data/` on first run, not baked
into the image (see §7.2 for why). `install-atrocore.sh` installs the application files
(via `bootstrap-web-data.sh`) and then completes AtroCore's own installation — the scaffold
is not the installation: without it
`'isInstalled' => false`, the `user` table is empty, `/api/v1/App/user` answers `500` and
every consumer sees a broken AtroCore. `install-metadata.sh` then copies the tracked model
and the schema is created:

    ./scripts/install-atrocore.sh --yes    # bootstrap web-data/ + install (rebuilds the DB)
    ./scripts/install-metadata.sh          # copy the tracked model into web-data/
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
    docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run

Without this, `http://localhost` has no DocumentRoot, the API answers `500`, and every seed
fails on missing tables. §7.2 repeats it in the demo context.

Health check — `/health` tells you which of those two states you are in:

    curl -f http://localhost/health

`{"status":"ok","installed":true,"configured":true}` means the application is on disk and the
installer has written `data/config.php`. `503` with `"status":"not_installed"` means `web-data/`
is empty and the commands above have not run. It is served from the image, not from
`web-data/`, so it answers even when there is no application at all — which is the case it
exists to name. It reads the local filesystem only and never opens a database connection, so
it says nothing about whether Postgres is reachable; `docker compose ps` covers that through
the `db` service's own healthcheck.

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

Health check:

    curl -f http://localhost:1880/health

Exempt from the API-key guard, and served by a flow rather than by Node-RED itself — so a `200`
means `flows.json` loaded and the gateway is answering, not merely that the runtime is up. It
does not probe AtroCore or Alfresco; see `compliance_flow/README.md` for why.

Basic endpoint check (example) — this one does reach AtroCore:

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

Verified end to end against a running stack, and — since 2026-09-16 — **from an empty checkout
by CI**: `atrocore-docker`'s `demo:verify` job (manual/scheduled, not a merge gate) clones the
sibling repositories, builds and starts every service and runs the quickstart, green in 7m24s.
What that run asserts, what the demo deliberately leaves to a human, and the open items it
surfaced are recorded in `TECHNICAL_DEBT_ANALYSIS.md` §4.8 ("Lean-demo status"); this section is
how to do the same thing by hand. Every command here has been executed and the intermediate
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

**Two preparation steps first, on a fresh checkout.** `compliance_cmis` writes its content store
into `./data/alf_data`, a bind mount that is gitignored — so a clone has no such directory,
Docker creates it `root:root 0755`, and the container (uid 33000) cannot create
`contentstore.deleted` inside it. Alfresco's `FileContentStore` then fails
(`Failed to create store root: ./alf_data/contentstore.deleted`), the `/alfresco` webapp never
deploys, and the container reports `unhealthy` — which reads like a model or database fault.
One command creates it with the ownership the container needs:

    cd compliance_cmis && ./scripts/bootstrap-alf-data.sh

and, for the same reason (a bind mount of a tracked directory, written by a container that does not
run as your user), the Node-RED data directory:

    cd compliance_flow && ./scripts/bootstrap-node-red-data.sh

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
    ./scripts/seed-usoap-vocabularies.sh --yes           # required: the enums the catalog points at
    ./scripts/seed-icao-reference-data.sh --yes          # required: ICAO Annex documents/paragraphs/PQs
    ./scripts/seed-usoap-evidence-expectations.sh --yes  # required: 48 evidence expectations (needs the PQs above)
    ./scripts/seed-nomenclatura.sh --yes                 # required: catalogs; 3 default specialties (ATS/NAV/MET)
    ./scripts/install-layouts.sh --yes           # required: the menu + the 123 tracked layouts
    ./scripts/seed-demo-dataset.sh --yes         # the demo dataset (synthetic; skip for a real deployment)
    # or: make bootstrap / make metadata-install / make db-seed-vocabularies YES=1 …

The seeds are **not all demo data**. The first four create the reference catalogs every
deployment needs — the USOAP/risk extensible enums, the ICAO Annex/Protocol-Question catalog, the
USOAP evidence-expectation catalog that `compliance_cmis`'s CE-evidence report resolves its
sampled-population ("Type-2") PQs from, and the Specialty/ActivityType/FindingSeverity rows —
and the data packs cannot resolve a `SpecialtyCode`, `ActivityTypeCode` or
`Normativa.AnnexParagraphID` without them. The expectation seed must run **after** the ICAO one:
each of its 48 rows is matched to its parent Protocol Question by `code`. Only
`seed-demo-dataset.sh` is synthetic and optional. `install-layouts.sh` is required for the UI
either way: until it runs, the admin menu is AtroCore's stock one (Product/File/Attribute/…) and
none of this platform's entities are reachable, because AtroCore reads the menu from
`layout_profile.navigation` and layout content from the `layout` table — never from the
`metadata/layouts/` that `install-metadata.sh` copies into `data/layouts/`.

A **real deployment wants its own records, not the demo dataset.** Two interchangeable routes
exist for the authority data an inspection needs (locations, providers, contacts, inspectors,
service areas, assignment groups, regulations and their articles, location services):
`./scripts/seed-starter-dataset.sh --yes` (placeholder `starter-` rows to edit, applied with
`psql`) or `./scripts/import-data-pack.sh --all` (the same records as editable CSV, loaded
through AtroCore's own import module — see `data-packs/README.md`). Use one or the other; they
write the same rows. The import feeds themselves do not exist until the pack runner runs: there
is no tracked `ImportFeed` metadata, so it creates each feed and its column mappings over the
API on first import.

On a **clean clone the first command is doing two jobs.** `./web-data` is bind-mounted over
`/var/www/`, and the `atro-web` image contains no AtroCore application at all — it's
installed directly into `web-data/` at bootstrap time (`scripts/bootstrap-web-data.sh` runs
`prepare-pim.sh`, the same install sequence the Dockerfile used to run at build time, inside
a throwaway container against the bind-mounted directory), rather than baked into the
image's build layers. This is deliberate: AtroCore's core packages are GPL-3.0-only, and
installing them at build time would mean any pre-built copy of this image carried GPL-3.0
source — installing at bootstrap time instead means the image itself never contains it, only
the generic PHP+Apache base. `install-metadata.sh` detects the missing `web-data/<domain>/`
and calls `scripts/bootstrap-web-data.sh` for you; `sql diff --run` then creates the schema.
Run `make bootstrap` (or the script directly) if you want that step on its own.

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

`seed-icao-reference-data.sh` is likewise not demo data: it loads the real ICAO Annex
documents, Annex paragraphs and USOAP Protocol Questions the citation chain
(`ChecklistQuestion → Normativa → AcapiteOACI → UsoapProtocolQuestion`) is built on top of —
without it, only the synthetic `PQ 99.x` chain the demo dataset itself creates exists, and
`sql/seed-usoap-evidence-expectations.sql` (which resolves its rows' parent PQ by `code`)
silently resolves every row to `NULL`. Unlike `Normativa` — a specific country's national
regulation, which each adopting authority enters on its own — this catalog is ICAO-standard
and belongs in every install: **15 Annex documents, 1,890 Annex paragraphs, 281 Protocol
Questions, 439 citations.**

Result: **90 demo rows across 25 tables**, plus **2,625 ICAO reference rows** — one fictional
airport, two service providers, three inspectors, **two site visits**, three inspections, the
interview schedules the plan generator needs, a checklist catalog (three topics, nine
questions) with its USOAP citation chain, the per-inspection selections `/checklist` actually
reads, and the full ICAO Annex/Protocol Question catalog underneath it.

**The two visits exist because the demo walks two halves of the lifecycle that cannot share a
date** (§7.4 — the payload dates are derived from the visit the inspection belongs to):

| Visit | Dates | Status | Used for |
|---|---|---|---|
| `V-ZZZZ-2026-01` (`demo-sv-01`) | `CURRENT_DATE - 30` → `-29` | `Complete` | the ATS and MET inspections, whose checklists and findings are imported and whose finding is walked through closure — so a closure is reviewed *after* the finding was issued |
| `V-ZZZZ-2026-02` (`demo-sv-02`) | `CURRENT_DATE + 21` → `+22` | `Planned` | the planning walkthrough: `GET /inspectionPlan` on `demo-iprov-ans-02` renders the plan and moves `AV-ZZZZ-A-0002` from `Assigned` to `Planned` |

Both visits are re-dated relative to the day the seed runs, so the demo is coherent whenever it
is seeded — that is why the quickstart reads the window back from `demo-sv-01` and stamps the
payload dates with it rather than embedding dates in the ZIPs.

### 7.3 Demo identities and site content (`compliance_cmis`)

**On a fresh instance, create the site the model lives in — before any import.** Every path the
webscripts resolve is under one Share site, and nothing tracked used to create it: a clean instance
came up, installed, seeded and logged in, and then failed its first canonical import with
*"Destination base folder not found: Sites/vigilancia-de-la-so/documentLibrary/Vigilancia/Inspecciones"*.

    cd compliance_cmis
    ./scripts/bootstrap-site-content.sh --yes

It creates the site `vigilancia-de-la-so`, the folders `Vigilancia/{Inspecciones, Datos de campo,
Hallazgos, Template data}` and `Documentos/Formatos`, and uploads the five `.fodt` templates from
`templates/`. Idempotent — it creates only what is missing — so it is also how you confirm an
existing instance is complete. The quickstart runs it as step 1c.

Then the demo identities:

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
- **A bind mount hides the image's contents, and the image no longer has AtroCore in it
  anyway.** `./web-data:/var/www/` means a clean clone starts with an empty `/var/www`, no
  DocumentRoot, and a metadata install that fails with advice the stack cannot satisfy — this
  was a named volume until commit `25affed`, which Docker *does* populate from the image.
  `scripts/bootstrap-web-data.sh` (run for you by `install-metadata.sh`, or `make bootstrap`)
  installs AtroCore directly into `web-data/` at first run instead of copying it out of the
  image, since the image is deliberately built without AtroCore's GPL-3.0 source baked in.
  (§5.1, §7.2.)
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

## 7.9 Monitoring (optional — `observability/`)

Prometheus, Alertmanager, Grafana and Loki, as a **separate Compose project**
that adds nothing to the six application stacks and sits on nothing's startup
path:

    cp observability/.env.example observability/.env   # set the Grafana and DB passwords
    docker compose -f observability/docker-compose.yaml up -d

Grafana at `http://127.0.0.1:3001`, Prometheus at `:9090`, Alertmanager at
`:9093` — all loopback-bound by default. Full detail in
`observability/README.md`.

**Start it after the platform, not before.** Every network it uses is
`external` and created by one of the six application projects; on a host where
they have never run it fails with "network not found".

Two things it is worth knowing it catches, because §8 below cannot:

- **A dead ActiveMQ.** Verified 2026-09-27: with the broker stopped, Alfresco's
  `-ready-` probe answered `200` and every service's `/health` reported green,
  while (per `FOOTPRINT_AUDIT.md`) replanning an existing document hangs
  forever with no error. The TCP probe of `activemq:61616` alerted 2m16s after
  the broker stopped. Nothing else on this platform notices.
- **WAL archiving stalling.** A failing `archive_command` does not stop
  PostgreSQL; it retains every segment until the volume fills, hours later.

Prove it works rather than assuming it:

    ./scripts/verify-observability.sh

It stops a container on purpose, waits for the alert to fire, confirms
Alertmanager received it, restarts the container and waits for the alert to
clear.

## 7.10 Offsite backups (`backup-destinations/`)

`backup-platform.sh` writes backup sets to a local directory. That protects
the data but not the host: a fire, a theft or a failed array takes the sets
with it. `scripts/backup-offsite.sh` is the other half.

    export BACKUP_DESTINATION=rsync-ssh
    export BACKUP_DEST_SSH=backup@dr.authority.example
    export BACKUP_DEST_PATH=/srv/oversight-backups

    ./scripts/backup-platform.sh --yes      # take the set
    ./scripts/backup-offsite.sh push        # copy it offsite
    ./scripts/backup-offsite.sh verify      # read it back and re-check every sha256
    ./scripts/backup-offsite.sh prune       # expire old sets at the destination

Three drivers ship — `local` (a second disk or an NFS mount), `rsync-ssh`
(any second host), and `s3` (AWS, MinIO, Ceph, Wasabi, most national cloud
offerings). Each authority's infrastructure differs, so the destination is a
**driver**, not a setting: see `backup-destinations/README.md` for the
five-verb contract and for writing your own.

**Run the conformance test against your destination before relying on it:**

    BACKUP_DESTINATION=<driver> ./scripts/verify-backup-destination.sh

It pushes a synthetic set, pulls it back, compares every byte, and exercises
pruning. Nobody here can test your Azure tenancy or your tape robot — the
contract is verified in CI, the backend is verified by you. Point it at a
*scratch* path or bucket: it exercises `prune`, and it refuses to start if
the destination already holds sets that are not its own.

**`verify` is the one to schedule.** An offsite copy nobody has ever read
back is a hope rather than a backup, and it is the cheapest check that turns
one into the other.

### WAL, shipped asynchronously

Backup sets bound your recovery point to the last backup. WAL closes the gap
to five minutes (`archive_timeout=300`) — but only once it is offsite too.

    ./scripts/ship-wal-archive.sh                  # all three archives
    ./scripts/ship-wal-archive.sh --dry-run        # what would be shipped
    ./scripts/ship-wal-archive.sh --prune-local 45 # also expire shipped, old segments

**Point it at a different path or prefix from your backup sets.** WAL is small
and frequent, sets are large and rare, and they want different retention.

> **Do not put the destination in `archive_command`.** It runs *inside*
> PostgreSQL, synchronously, once per 16 MB segment, and PostgreSQL will not
> recycle a segment until it returns success. A network there makes latency a
> database problem — a slow destination throttles WAL recycling and
> eventually writes — and a failure a disk problem, because unarchived
> segments accumulate until the volume fills and the database stops. Archive
> locally, ship separately. If the destination is unreachable the segments
> queue and the database does not care.

Three properties worth knowing:

- **Segments are recorded as shipped only after the push succeeds.** The
  other order loses data permanently: a failed transfer would mark them done,
  never retry, and the next local prune would delete them.
- **`--prune-local` is off by default.** A segment is removed only when it is
  both confirmed shipped *and* older than the age given. Pass an age **at
  least as long as your backup-set retention** — deleting WAL newer than your
  oldest base backup destroys point-in-time recovery from it, and nothing will
  tell you until a restore.
- **Segments are read through a container when they are not readable by the
  invoking user.** PostgreSQL writes them mode 0600 as its own uid; all three
  archives here are owned by uid 70. This is detected, not assumed, so an
  unreadable archive is an error rather than a quiet "nothing to ship".

`WAL_SHIP_BATCH_MAX` (default 512) caps a run. At 16 MB a segment, a backlog
of a few hundred is several gigabytes of staging — worth bounding on a small
host.

### Restoring from the offsite copy

The sequence, exercised end to end against a live platform on 2026-09-29:

    ./scripts/backup-offsite.sh list                       # pick a set
    ./scripts/backup-offsite.sh pull <set-id> --into /tmp/recover/<set-id>
    cd ../compliance_cmis && docker compose stop alfresco  # see below
    cd ../atrocore-docker
    ./scripts/restore-platform.sh --yes --from /tmp/recover/<set-id>
    cd ../compliance_cmis && docker compose start alfresco

**Alfresco must be stopped** before its content store is replaced, and
`restore-platform.sh` refuses rather than corrupting a live store. The
databases stay up: they are restored through `docker compose exec`.

`pull` verifies every checksum on arrival and `restore-platform.sh` verifies
them again before touching anything, so a set that fails either is refused
rather than half-applied.

**Solr is not restored** — it is derived state. Search-backed reads are
incomplete until Alfresco reindexes, which is why the script says so and why
`compliance_flow/scripts/smoke-flows.mjs` is the check that matters before
declaring recovery complete.

What the 2026-09-29 drill confirmed after restoring: 155/70/9 tables across
the three databases, 6,271 content files, all seven inspection folders, smoke
15/15, error envelope 5/5, and finding `H-ZZZZA0001-ATS-001` back in its
exact workflow state — `Pending Closure Approval`, not merely present.

## 7.11 Scheduling (`deploy/systemd/`)

Three timers turn the backup scripts from things somebody has to remember
into things that happen: a nightly set pushed offsite and pruned, WAL shipped
every fifteen minutes, and a weekly read-back verification. Install with
`scripts/install-backup-timers.sh --system`; full detail in
`deploy/systemd/README.md`.

Every run records its outcome where Prometheus can see it, because a timer
that stops firing and a timer that fails nightly both look exactly like a
healthy system. Five alerts watch those metrics, and the one to understand is
**`BackupNeverRan`** — it fires on `absent()`, because a timer nobody enabled
produces no metric at all and every threshold rule reads that as fine.

`BACKUP_METRICS_DIR` must name the same directory the observability stack
mounts for node-exporter, or the metrics are written and never read.

## 7.12 Point-in-time recovery (`scripts/restore-pitr.sh`)

A backup set rewinds to last night. WAL rewinds to five minutes ago — but
only through a *physical* base backup, which is why `backup-platform.sh`
stores a `*.basebackup.tar` per database alongside the logical dumps. A
`pg_dump` cannot be combined with WAL at all.

Recover one database to a moment:

```bash
./scripts/restore-pitr.sh \
  --dataset atrocore \
  --base /srv/backups/20260929T173614Z/atrocore.basebackup.tar \
  --target-time "2026-09-29 17:30:24+00"
```

It brings the recovered database up **beside** the live one, on port 55432,
and writes nothing to any running service. That is deliberate: a
point-in-time recovery is a hypothesis about when the damage happened, the
first guess is usually wrong, and restoring over the live cluster makes every
attempt destructive. Inspect the result, then promote it by dumping from it
and restoring deliberately.

The WAL archive is mounted **read-only** and archiving is off on the
recovered instance. After the recovery target the instance is on a diverged
timeline, and letting it write into the archive would corrupt the input to
every later recovery.

Three things worth knowing before you need this at 3am:

- **Asking for a time beyond the archive fails loudly**, with
  `recovery ended before configured recovery target was reached`. The script
  then prints the latest time you *can* reach, taken from the server's own
  log. It does not hand you a database recovered to the wrong point.
- **`--target-time latest`** replays everything available, for the case where
  you want the last committed transaction rather than a specific moment.
- **The database alone is not the platform.** The Alfresco content store is
  not WAL-protected; a database recovered to a time its content store does
  not match will reference files that are not there. For whole-platform
  recovery use `restore-platform.sh`. This tool is for rewinding one database
  past a bad write.

### The drill

`scripts/verify-pitr.sh` proves the chain end to end, and is the reason any
of the above can be relied on:

```
base backup -> marker A -> T -> marker B -> WAL switch -> recover to T
```

It then asserts A is present and **B is absent**. The absence is the whole
test: a recovery that replays everything also contains A, so finding A proves
only that the base backup works. Only B's absence shows replay stopped where
it was told.

It writes one table, `pitr_drill_marker`, into the **live** cluster and drops
it on every exit path — a drill against a database nobody uses proves nothing
about this platform's WAL configuration. `pitr:verify` runs it in CI, manual
or scheduled.

**What the 2026-09-29 drill found on its first run:** AtroCore's base backup
had never been produced. `backup-platform.sh` passed `POSTGRES_PIM_USER` to
`pg_basebackup`, and this image's application role (`usuario`) has neither
SUPERUSER nor REPLICATION, so every attempt failed with *must be superuser or
replication role to start walsender* — and because that failure only warned,
the run still printed "Backup set complete". Point-in-time recovery for
AtroCore was impossible, and nothing said so. Fixed by connecting as
`postgres`; a failed base backup now counts as a skipped dataset, so the run
exits non-zero and the backup alerts fire, and the MANIFEST carries a `pitr:`
block stating per dataset whether the set can recover to a point in time.

**What it proved afterwards** (AtroCore, against a base backup from a real
stored set): 3 WAL segments replayed from the archive, `recovery stopping
before commit of transaction 46471, time 2026-09-29 17:37:29.800322+00`,
marker A present, marker B absent, and the live database untouched.

**What drilling the other two datasets found (same day).** The AtroCore drill
passing told us less than it appeared to, because AtroCore is the dataset
whose PostgreSQL settings are all defaults. Two defects surfaced the moment
`--dataset alfresco` ran, both of which would have been met for the first
time during an actual incident:

- **Alfresco's recovery aborted outright**, with `recovery aborted because of
  insufficient parameter settings — max_connections = 100 is a lower setting
  than on the primary server, where its value was 300`. A recovering server
  refuses to start when `max_connections`, `max_worker_processes`,
  `max_wal_senders`, `max_prepared_transactions` or `max_locks_per_transaction`
  is below the primary's, because those values size shared structures the WAL
  records depend on. Alfresco sets `max_connections=300` on its compose
  `command:` line — which lives nowhere inside `PGDATA`, so no base backup
  carries it. The primary's values *are* recorded in `pg_control`, which does
  travel inside the base backup, so `restore-pitr.sh` now reads them with
  `pg_controldata` and passes them back as `-c` overrides. That works with the
  source host gone, which a lookup against the live server would not.
- **Every assertion was querying as the wrong role.** Both scripts used
  `psql -U postgres`, which is correct only for AtroCore: a physical backup
  carries the source cluster's roles, and Alfresco's bootstrap superuser is
  `alfresco`, compliance_web's is `POSTGRES_USER` (`compliance`). Neither
  cluster has a `postgres` role at all. Through the scripts' own `2>/dev/null`
  this returned empty rather than erroring, so the wait loop could not see the
  promotion and timed out after 240s on a recovery that had in fact succeeded.
  Both scripts now resolve the superuser per dataset; `restore-pitr.sh` takes
  `--superuser` to override it.

All three datasets now pass 13/13 — AtroCore (PG 15), Alfresco (PG 16.5,
3 segments replayed, stopping before transaction 1814838) and compliance_web
(PG 16, 3 segments, stopping before transaction 915) — each with marker A
present, marker B absent, and the live database untouched.

**The WAL archive had no retention**, which the drill turned up by filling the
disk. Measured 2026-09-29, ~2.5 days after archiving was switched on:
`compliance_cmis/data/wal-archive` 5.5 GB / 350 segments,
`atrocore-docker/wal-archive` 1.2 GB / 85, `compliance_web/data/wal-archive`
529 MB / 37 — about **3 GB/day and growing**, on a host that had reached 99%.
Fixed the same day; see §7.13.

**Still not measured: RTO on production-sized data.** The AtroCore database
here is 59 MB and recovers in seconds. That number says nothing about a real
authority's dataset, and §5.2 of the production plan keeps its RTO figure as
a target.

## 7.13 WAL retention (`scripts/prune-wal-archive.sh`)

`archive_mode=on` with `archive_timeout=300` buys the five-minute RPO by
writing a 16 MB segment at least every five minutes, per database, forever.
Nothing reclaimed them, so the archive that exists to prevent data loss was
on course to cause an outage: when the volume fills, `archive_command` starts
failing, PostgreSQL retains WAL in `pg_wal` rather than discarding it, and the
database stops.

```bash
./scripts/prune-wal-archive.sh                # dry run, all three datasets
./scripts/prune-wal-archive.sh --yes          # apply
```

`backup-platform.sh` calls it at the end of its retention step, so a host on
the nightly timer needs nothing else. It runs **after** old sets are pruned,
so the boundary reflects what is still kept.

**The boundary is a base backup, not a date.** "Delete WAL older than N days"
is the obvious rule and it is wrong in both directions: too small and it
silently destroys point-in-time recovery from a backup you are still keeping,
too large and the archive grows without bound. A base backup can only replay
forward from the segment it started in, and that segment's name is written
inside the backup itself:

```
START WAL LOCATION: 2/6C000028 (file 00000001000000020000006C)
```

So the cut is taken at the START WAL of the **oldest retained** base backup —
read out of its own `backup_label` by `scripts/wal-anchor.lib.sh`, which
`ship-wal-archive.sh --prune-local` now shares. WAL retention then follows set
retention automatically: prune a set and the boundary moves forward, keep a
set longer and the WAL it needs is kept with it.

**With no base backup it refuses and exits non-zero**, rather than freeing the
disk. That state is real — a dataset whose base backup failed has no anchor,
which is exactly where AtroCore was for days — and the answer is to fix the
backup, not to delete the evidence.

**The anchor is local.** A base backup that exists only at the offsite
destination is invisible to it, and the WAL that would replay onto it will be
pruned as unreachable. That is the one way this can destroy recovery from a
backup you still hold. If you keep older sets offsite, pass `--anchor` with
that backup's START WAL, or ship the archive with them and prune only what
`ship-wal-archive.sh` has confirmed shipped.

`ship-wal-archive.sh --prune-local` previously enforced only "shipped, and
older than N days", with a comment telling the operator to choose N at least
as large as their set retention. Nothing checked it. It now applies the same
anchor as a hard floor, and a stream with no base backup is not pruned at all.

### What the first run did

Against this platform on 2026-09-29, with one retained set:

| dataset | removed | kept | freed |
|---|---|---|---|
| atrocore | 80 | 12 | ~1.3 GB |
| alfresco | 371 | 8 | ~5.9 GB |
| compliance_web | 41 | 8 | ~0.7 GB |

492 segments, and the disk went from **99% to 87%**. A first run is usually
this dramatic: the WAL written before your oldest base backup cannot be
replayed by anything you hold, so it is dead weight rather than recovery
capability. Look at the dry run before believing it.

Then all three PITR drills were re-run **against that set's stored base
backups**, to prove the pruning had not cut into anything load-bearing: 13/13
each, 3 segments replayed per dataset, marker A present and marker B absent,
from archives now holding 9, 9 and 13 segments. `restore-platform.sh` still
parses the set to exactly its seven files.

**It refuses when the mount cannot see the archive.** `pg_archivecleanup`
normally runs in a container, because a real archive belongs to the database's
uid at mode 0700 and the invoking user cannot read it — which makes the tool
depend on a bind mount resolving to the directory you meant. Where the Docker
daemon is not on the caller's filesystem (docker-in-docker, a remote daemon, a
path that does not exist on the daemon's side) it silently does not: Docker
creates an empty directory, `pg_archivecleanup` finds nothing, and the run
reports *would remove 0 of 0 segments* and exits 0. An archive growing without
bound while something reports success every night is precisely what this tool
exists to prevent, so when the archive is readable from here the count seen
through the mount is compared with the count seen directly and a disagreement
is fatal. When it is not readable — the normal case on a real host — there is
nothing to compare and the container's view is trusted. `--local`
(`WAL_PRUNE_LOCAL=1`) skips the container entirely for hosts that have
`pg_archivecleanup` installed and an archive the caller can read.

This was found by this repository's own CI. The conformance test's fixtures
live on the job container; the job used dind; the mount reached the daemon;
three checks failed with nothing pruned.

`scripts/verify-wal-pruning.sh` (18 checks, `validate:wal-retention`, a merge
gate) is the conformance test. It runs on synthetic fixtures — empty files
named like WAL segments, and tars containing nothing but a `backup_label` — so
it needs no database and no stack. It takes `pg_archivecleanup` from PATH when
one is installed and from a container otherwise, so CI exercises the direct
path and a developer without the binary exercises the container path. What it checks is the boundary rather than
the deletion: that the anchor is the oldest retained backup and not the
newest, that it is ordered by the segment part rather than the timeline
prefix, that the anchor segment and everything after it survive, that
`.history` files survive, and that with no base backup nothing is deleted.
Each was mutation-tested.

## 7.14 Recovery time (`scripts/measure-rto.sh`)

An RTO is the number a DR plan is judged by, and this platform had never
produced one. The restore drill proved a backup restores a working system; it
never timed it, and §5.2 carried a figure inherited from a design document.

```bash
./scripts/measure-rto.sh --from /srv/backups/20260929T213923Z \
  --project-nodes 250000 --project-content-gb 200
```

**It stops the clock later than the restore does, on purpose.**
`restore-platform.sh` finishes when the data is back. `restore-verify-ci.sh`
then checks the system answers — and until 2026-09-30 it *tolerated a
partially failing smoke matrix as "expected while Solr reindexes"*, because
it left the existing index in place and so could not tell an index still
catching up from one that never would. It now destroys the index alongside
the databases and the content store, waits for the rebuild, and requires the
smoke matrix to pass; the two scripts share
`scripts/solr-index.lib.sh` so they cannot drift on what "search is back"
means. What still separates them is only the clock: the drill proves a
recovery works, this measures how long it takes. Neither on its own was an
RTO: Solr is derived state and deliberately not backed up,
so on a blank host it does not exist, and the reads that depend on it are not
incidental — the checklist endpoint, open findings, and four report Web
Scripts. A recovery that has restored every byte and cannot answer *which
findings are open* has not recovered. So this removes Solr's index before
restoring, which is the state a real recovery starts from, and keeps the
clock running until the index is rebuilt and the gateway smoke matrix passes.

**Two guards, because a reindex is easy to fake.** The index size is recorded
before the wipe and the phase is not over until the rebuilt index reaches it —
"zero transactions remaining" alone is what an index that has not started
tracking reports, so a loop waiting on that returns in seconds with a
meaningless number. That catches an index that never fills; it does not catch
one that was never emptied, so the Solr volume IDs are read before removal and
asserted gone afterwards, and the low-water mark seen during the rebuild is
reported and must be below the target. Both were mutation-tested — removing
the container without its volumes aborts the run before anything is restored.

### The measurement (2026-09-29)

Two runs against the live platform, restoring set `20260929T213923Z`:
**1m50s** and **1m40s** to a searching, serving system, smoke matrix 15/15
both times. The second run's breakdown:

| phase | | |
|---|---|---|
| teardown | 12.3s | fixed |
| verify set (690 MB) | 1.8s | size-dependent |
| content store (790 MB) | 7.6s | size-dependent, 104 MB/s |
| databases (3 dumps) | 8.5s | size-dependent |
| Alfresco ready | 40.4s | fixed |
| search correct again | 23.1s | size-dependent, 1,242 nodes |
| smoke matrix | 6.8s | fixed |
| **total** | **1m40s** | |

**At this scale the platform is dominated by fixed cost** — 59.8s of the 100s
is teardown, JVM startup and the smoke matrix, and does not grow with data.
That is the useful shape: everything that scales is 41s, and 23s of it is
indexing.

**Extrapolating, with the caveats stated.** `--project-nodes` and
`--project-content-gb` scale the size-dependent phases and leave the fixed
ones alone. For 250,000 nodes and 200 GB of content that gives **about 2.6
hours, of which ~78 minutes is reindexing**. This is arithmetic on one
measurement, not a second measurement. It reads **low**, for three reasons
worth knowing before quoting it:

- Solr starts with Alfresco, so on a dataset this small most of the indexing
  finishes while the stack is still booting and is charged to the fixed term.
  The wall-clock rate here is 18.7 ms/node; Solr's own per-node mean, which
  excludes tracker polling, is 9.9 ms/node. The truth is between them and the
  gap closes only as indexing outlasts startup.
- Alfresco indexing is not perfectly linear at scale.
- A real authority's documents are larger per node than a demo dataset's.

**Every restore is now a data point.** `restore-platform.sh` times its phases
and prints the breakdown, and appends a machine-readable line when
`RTO_RECORD` names a file. `restore-verify-ci.sh` sets it, and `restore:verify`
publishes `rto-measurements.jsonl` as a 90-day artifact, so the figure can be
trended rather than re-derived whenever someone asks.

**Still not measured on production-sized data**, and no arithmetic substitutes
for that. What this replaces is a number with no measurement behind it at all.

## 7.15 Offsite backup encryption (`BACKUP_AGE_RECIPIENT`)

An offsite destination is, by definition, storage this platform does not
control — a cloud tenancy, a courier, a disk in another building. Everything
`backup-offsite.sh` sends there used to go in the clear: three databases and
the whole content store, readable by whoever holds the storage.

```bash
# Generate the keypair somewhere OTHER than the backup host
age-keygen -o escrow.key          # -> escrow, off-host, never on this machine
age-keygen -y escrow.key          # -> BACKUP_AGE_RECIPIENT in atrocore-docker/.env
```

With `BACKUP_AGE_RECIPIENT` set, every file is encrypted before a driver sees
it. The destination receives `*.age` files and a plaintext `ENCRYPTED` index,
and nothing else — the `MANIFEST` is encrypted too, because it names every
file and carries plaintext hashes.

**Public-key, so the host cannot read its own backups.** This machine holds
only the recipient key. It can encrypt backups and cannot decrypt any of
them, including last year's. Whoever takes the server gets the data that is
on it, and not the backup history as well — which is the difference between
a bad day and a total loss. `push` **refuses to run** if the escrowed private
key is found on this host, because keeping it here silently gives that
property away, and `preflight-secrets.sh --production` refuses too.

**Local sets stay in plaintext, deliberately.** Decryption needs the escrowed
key, and requiring an escrow retrieval for the ordinary same-host restore
would add an unbounded delay to a recovery measured at 1m40s (§7.14). The
threat this addresses is the copy held by someone else, and that is what it
encrypts. If the backup volume itself is a threat in your deployment — a
stolen disk rather than a hostile destination — that is a different decision
and this is not it.

**Verification needs no key.** The `ENCRYPTED` index lists the sha256 of
every *ciphertext* file, so `backup-offsite.sh verify` proves an offsite copy
is intact without anyone taking the private key out of escrow. Reading the
contents needs the key; proving the bytes survived does not — which is what
makes a routine integrity check something that will actually be run.

### Restoring from an encrypted offsite copy

```bash
# Retrieve the private key from escrow, then:
BACKUP_AGE_IDENTITY_FILE=/secure/escrow.key \
  ./scripts/backup-offsite.sh pull 20260930T030000Z --into /srv/restore/20260930T030000Z
./scripts/restore-platform.sh --from /srv/restore/20260930T030000Z
```

`pull` verifies the ciphertext index, decrypts, then verifies the set's own
MANIFEST — two layers, each doing its own job. `restore-platform.sh` then
sees an ordinary plaintext set and behaves exactly as it always has.

**The key-escrow decision is the authority's, and it is the part that
actually matters.** An encrypted backup whose key is lost is not a backup.
Decide where the private key lives, who can retrieve it, and how that is
tested, before turning this on — and test the retrieval, not just the
encryption.

`scripts/verify-backup-encryption.sh` (17 checks, in `validate:backup-destination`,
a merge gate) is the conformance test: synthetic fixtures and the `local`
driver, so it needs no cloud tenancy and no network. It asserts the
destination receives ciphertext and nothing else, that verification works
with no key, that tampering is caught with no key, that a pull with the key
reproduces the original byte-for-byte, and that all three refusals fire —
no recipient, private key on the host, and a private key pasted into the
recipient variable.

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
- **A restore refuses a set that looks complete**, reporting the WAL archive
  names as missing files:
  - fixed in 2026-09-29. Before that, `restore-platform.sh` parsed both
    `- name:` lists in the MANIFEST and read the three `wal_archives:` labels
    as files, so it refused **every set taken after WAL archiving was added**.
    If you are running an older checkout, that is what you are seeing, and the
    set itself is fine.
- **Everything answers, but an operation never returns** — no error, no timeout, no log line:
  - suspect ActiveMQ before anything else. `cd compliance_cmis && docker compose ps activemq`.
    This failure is invisible to every health check in this guide, which is
    why §7.9 exists; the monitoring stack's `ActiveMQBrokerUnreachable` alert
    is the only automatic detection of it.

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

- **There is a script for this now.** `atrocore-docker/scripts/preflight-secrets.sh` checks a
  whole workspace's `.env` files without needing Docker, a running stack or the network:

      ./scripts/preflight-secrets.sh                        # demo profile (default)
      ./scripts/preflight-secrets.sh --profile production   # the gate

  The **demo** profile reports the published values and exits 0, so it never blocks the demo. The
  **production** profile treats every value published in these repositories as a failure, and also
  catches the structural mistakes that leave a deployment insecure without looking wrong: the three
  gateway keys not matching each other (the gateway then rejects its own callers), a key short
  enough to be guessable, a service still in development mode — which is what arms each service's
  own startup secret guard — and session cookies left insecure. Run it after rotating, before
  exposing anything. `make preflight-secrets-production` is the same thing.

  Two things it cannot see, because they are not in a `.env`: `compliance_checklist`'s own copy of
  the gateway key, which is entered in the app, and the demo identities, which live in Alfresco
  (`compliance_cmis/scripts/seed-demo-identities.sh --remove`).

- **For production-like usage, replace every development/demo default for credentials and secrets before the stack is reachable by anyone you do not trust.** This is a demo/reference stack, not a hardened deployment (Vault, Keycloak and replication are all still open; monitoring now exists but is a separate opt-in stack that the demo does not start — §7.9). Concretely, at minimum:
  - The gateway `API_KEY` (`compliance_flow/.env`) and its matching `NODE_RED_API_KEY` (`compliance_web/.env`) / `IMPORT_API_KEY` (`compliance_import/.env`) — all three ship with the **same public placeholder value**, committed to their respective repos. Generate one real value (`openssl rand -hex 32`) and set it in all three; `compliance_checklist` needs the same value entered in its own API-key setting.
  - The demo identities' passwords (`closure.reviewer`, `demo.inspector1` — §7.3 above) and, ideally, the accounts themselves (`./scripts/seed-demo-identities.sh --remove`).
  - `AUTH_TICKET_ENCRYPTION_KEY` (`compliance_web`), `NODE_RED_CREDENTIAL_SECRET` and `ADMIN_PASSWORD_HASH` (`compliance_flow`), and every `POSTGRES_*_PASSWORD` across the six `.env` files.
  - None of the above is optional hardening — an unrotated demo credential on a network-reachable instance is an open door, not a known limitation.
- Keep shared network names stable across all repos.
- Maintain one source of truth for endpoint/auth policy to avoid drift between web app, checklist app, and middleware.