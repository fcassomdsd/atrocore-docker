#!/usr/bin/env bash
#
# demo-quickstart.sh — take a running stack to a demonstrable demo dataset and a
# walking finding-closure workflow, in one command.
#
# This is the executable form of docs/COMPLIANCE_INTEGRATION_RUNBOOK.md §7 in this repo. Every step
# here has been run by hand and verified; the script exists so it does not have to
# be rediscovered. It assumes the stack is already up (runbook §3–§5), that the
# .env files from §4 exist, and that the six repositories are checked out side by
# side (it reaches into ../compliance_cmis, ../compliance_flow and ../compliance_import).
#
# It is ADDITIVE and idempotent: the seed scripts only ever write rows whose id
# starts with `demo-`, and each import re-supplies its own payload. Re-running it
# is safe; it will create a new follow-up version rather than mutating anything.
#
# Step 0b bootstraps the application into web-data/ and syncs the schema — without it
# a clean clone serves nothing at all (web-data/ is bind-mounted, so the app baked into
# the image is hidden) and the seeds fail on missing tables. Skipping it is only correct
# when the app and the custom tables are already there (`--skip-metadata`).
#
# The tracked metadata/ tree is a *partial overlay* (the files this project actually
# customises — see metadata/README.md). The operational entities the demo seeds write to —
# Location, ServiceProvider, SiteVisit, Inspector, ServiceArea, Finding … — come from the
# recovered entity definitions `install-metadata.sh` installs from it, and the tables are
# built by `sql diff --run`; a clean clone needs no dump. Step 0b fails loudly if that did
# not happen: the schema probe below reads `public.service_area` (override
# SCHEMA_PROBE_TABLE to exercise the failure path deliberately).

# The demo dataset dates the site visit relative to the day it is seeded
# (`CURRENT_DATE + 21` to `+ 22`), but the payloads it imports are ZIPs committed to
# compliance_import, which freeze their dates the day they are written. The inspection
# window lives on the Alfresco folder and is copied there from the payload by the canonical
# import, so importing a stale payload dates the demo's inspection into the wrong week.
# Step 2 therefore reads the window back from the seeded row and stamps a copy of every
# payload with it (`compliance_import/scripts/stamp-payload-window.py`); the tracked ZIP
# stays a template, and step 6 asserts the folder matches the seed.
#
# Step 1b seeds the demo identities (compliance_cmis/scripts/seed-demo-identities.sh):
# the closure review needs the `closure_reviewer` role, and — because an application
# role does not grant an Alfresco permission — repository access for that account too.
# The script prints the closure-review recipe (runbook §7.3) at the end.
#
# It does NOT walk the closure review itself: that is a UI/API decision by a human,
# so the last thing it prints is the two curl calls that exercise it.
#
# Usage: demo-quickstart.sh --yes [--skip-metadata] [--skip-seed] [--skip-import]

set -euo pipefail

# This script lives in atrocore-docker/scripts; the platform is the parent directory.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_DIR}/.." && pwd)"

# AtroCore serves the app under PRODUCTION_DOMAIN (default localhost); both the
# console path and the web-data/ layout follow it.
ATROCORE_DOMAIN="$(grep -E '^PRODUCTION_DOMAIN=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'" || true)"
ATROCORE_DOMAIN="${ATROCORE_DOMAIN:-localhost}"

# Every service URL below goes through this. It is `localhost` for a local run, and the dind
# service alias on a CI runner, where published ports are NOT on the job container's own
# localhost (see .gitlab-ci.yml and scripts/demo-verify-ci.sh). ATROCORE_DOMAIN is a different
# thing: it is the virtual host the app lives under inside the container.
DEMO_HOST="${DEMO_HOST:-localhost}"

# The database settings the seed scripts use, read once for the status assertions below.
POSTGRES_PIM_USER="$(grep -E '^POSTGRES_PIM_USER=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"
POSTGRES_PIM_DB="$(grep -E '^POSTGRES_PIM_DB=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"

CONFIRMED=0
SKIP_METADATA=0
SKIP_SEED=0
SKIP_IMPORT=0

for arg in "$@"; do
  case "${arg}" in
    --yes) CONFIRMED=1 ;;
    --skip-metadata) SKIP_METADATA=1 ;;
    --skip-seed) SKIP_SEED=1 ;;
    --skip-import) SKIP_IMPORT=1 ;;
    *) echo "Unknown argument: ${arg}"; exit 2 ;;
  esac
done

if [[ "${CONFIRMED}" != "1" ]]; then
  cat <<'USAGE'
This will:
  0b. bootstrap the AtroCore app into web-data/ and install the metadata (atrocore-docker)
  1. seed the USOAP vocabularies, the Nomenclatura catalogs and the demo dataset (atrocore-docker)
  1b. seed the demo identities closure.reviewer / demo.inspector1 (compliance_cmis)
  2. import the demo checklist/findings payload, the canonical documents and the follow-up
     (each payload stamped with the seeded site visit's window)
  3. run the read-only smoke harness and the error-envelope audit
  4. generate the oversight artifacts — plan, inspection report, provider history and the
     USOAP CE-evidence report — and assert each one exists

It is additive and idempotent. Run again with --yes to continue.
Usage: demo-quickstart.sh --yes [--skip-metadata] [--skip-seed] [--skip-import]
USAGE
  exit 1
fi

step() { printf '\n=== %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
die()  { printf '    FAIL %s\n' "$1" >&2; exit 1; }

json() { # json <file> <node expression over `j`
  node -e "const j=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));console.log($2)" "$1"
}

# ---------------------------------------------------------------------------
step "0. Preflight — the other services (AtroCore is bootstrapped and checked after step 0b)"
# ---------------------------------------------------------------------------
probe() { # probe <label> <url> <acceptable>
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$2" 2>/dev/null || true)
  case "$3" in
    *"$code"*) ok "$1 (:${2##*:} -> $code)" ;;
    *) die "$1 did not answer (HTTP ${code:-none}) — is the stack up? see runbook §5" ;;
  esac
}
# AtroCore itself is deliberately NOT probed here: on a clean clone `web-data/` is empty, so
# Apache has no DocumentRoot and answers 404 — step 0b bootstraps the application and probes it
# afterwards, which is the whole point of that step. Node-RED is probed on its editor root
# rather than `/specialties`, because that endpoint proxies to AtroCore and answers 400 until
# step 0b has run (and the seed after it has data).
probe "Alfresco"        "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-" "200"
probe "Node-RED"        "http://${DEMO_HOST}:1880/" "200 401"
probe "import service"  "http://${DEMO_HOST}:8000/health" "200"
probe "web backend"     "http://${DEMO_HOST}:4000/health" "200"

# compliance_flow/.env holds the *in-network* AtroCore address (`http://atro-web/api/v1`), which is
# right for Node-RED and wrong for anything this script runs against the published port — the
# install wizard in particular, which would then be told to reach a host it cannot resolve
# (`http://atro-web/api/v1 did not answer; is the stack up?` on a stack that is up). A caller's
# ATROCORE_BASE_URL is therefore preserved across the sourcing below.
CALLER_ATROCORE_BASE_URL="${ATROCORE_BASE_URL:-}"

set -a
# shellcheck disable=SC1091
. "${WORKSPACE_ROOT}/compliance_flow/.env"
set +a

if [[ -n "${CALLER_ATROCORE_BASE_URL}" ]]; then
  export ATROCORE_BASE_URL="${CALLER_ATROCORE_BASE_URL}"
fi

ticket() {
  curl -s -m 30 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/authentication/versions/1/tickets" \
    -H 'Content-Type: application/json' \
    -d "{\"userId\":\"${ALFRESCO_USERNAME}\",\"password\":\"${ALFRESCO_PASSWORD}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).entry.id)}catch(e){process.exit(1)}})'
}

# ---------------------------------------------------------------------------
if [[ "${SKIP_METADATA}" == "0" ]]; then
  step "0b. Metadata — bootstrap the app into web-data/ and sync the schema (atrocore-docker)"
  # On a clean clone web-data/ is empty and the compose bind mount hides the app
  # the image was built with, so this is what makes a fresh install demonstrable.
  # Re-runnable: the copy is skipped when web-data/ already exists, and `sql diff
  # --run` only applies what is missing.
  # Order matters: bootstrap the files, complete the application's own installation (which
  # rebuilds the database and creates the super admin), then install the tracked model and sync
  # the schema it describes.
  #
  # Console commands run as www-data, not as root: `docker compose exec` defaults to root, and
  # root-owned files in `data/cache` then make the web process (www-data) fail on its next cache
  # write, which surfaces as HTTP 500 on every API route.
  ( cd "${REPO_DIR}" \
    && ./scripts/bootstrap-web-data.sh \
    && ./scripts/install-atrocore.sh --yes \
    && ./scripts/install-metadata.sh >/dev/null \
    && docker compose exec -T -u www-data atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" clear cache >/dev/null \
    && docker compose exec -T -u www-data atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" sql diff --run >/dev/null ) \
    || die "metadata install failed (see docs/COMPLIANCE_INTEGRATION_RUNBOOK.md §7.2)"
  ok "application installed, metadata copied, cache cleared, schema synced"
else
  step "0b. Metadata install skipped"
fi

# Now that the application exists, check it, and check that the model really reached the
# database. A missing operational schema means the model was never installed/synced — the
# remedy is step 0b, not a dump.
# SCHEMA_PROBE_TABLE is overridable so the failure path can be exercised deliberately.
SCHEMA_PROBE_TABLE="${SCHEMA_PROBE_TABLE:-service_area}"
schema_ready() {
  local user db
  user="$(grep -E '^POSTGRES_PIM_USER=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"
  db="$(grep -E '^POSTGRES_PIM_DB=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"
  [[ -n "${user}" && -n "${db}" ]] || return 1
  ( cd "${REPO_DIR}" && docker compose exec -T db psql -U "${user}" -d "${db}" -tAc \
      "select to_regclass('public.${SCHEMA_PROBE_TABLE}') is not null" 2>/dev/null ) \
    | tr -d '[:space:]' | grep -q '^t$'
}
probe "AtroCore" "http://${DEMO_HOST}/api/v1/App/user" "401"
if schema_ready; then
  ok "operational schema present (public.${SCHEMA_PROBE_TABLE})"
else
  die "the AtroCore database has no operational schema (public.${SCHEMA_PROBE_TABLE} is missing).
         Install the tracked model and sync the schema — re-run this script without --skip-metadata,
         or by hand:
           ./scripts/install-metadata.sh
           docker compose exec -u www-data atro-web php /var/www/localhost/console.php clear cache
           docker compose exec -u www-data atro-web php /var/www/localhost/console.php sql diff --run
         See docs/COMPLIANCE_INTEGRATION_RUNBOOK.md §7.2. If the stack is still starting, wait for
         PostgreSQL and re-run."
fi

# ---------------------------------------------------------------------------
if [[ "${SKIP_SEED}" == "0" ]]; then
  step "1. Seed the reference catalogs and the demo dataset (atrocore-docker)"
  ( cd "${REPO_DIR}" \
    && ./scripts/seed-usoap-vocabularies.sh --yes >/dev/null \
    && ./scripts/seed-nomenclatura.sh --yes >/dev/null \
    && ./scripts/seed-demo-dataset.sh --yes >/dev/null ) \
    || die "seeding failed"
  ( cd "${REPO_DIR}" && docker compose exec -T -u www-data atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" clear cache >/dev/null 2>&1 ) || true
  ok "90 demo rows across 25 tables (airport ZZZZ, 2 providers, 3 inspectors, 3 inspections, 2 site visits, 9 questions + USOAP chain)"
else
  step "1. Seeding skipped"
fi

# The window the seed computed for the demo site visit — the anchor every payload date is
# derived from (see the note at the top of this file). Read from the database rather than
# recomputed here, so `--skip-seed` on an already-seeded stack uses the window that seed
# actually wrote.
DEMO_SITE_VISIT_ID="${DEMO_SITE_VISIT_ID:-demo-sv-01}"
demo_window() {
  local user db
  user="$(grep -E '^POSTGRES_PIM_USER=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"
  db="$(grep -E '^POSTGRES_PIM_DB=' "${REPO_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr -d "'")"
  [[ -n "${user}" && -n "${db}" ]] || return 1
  ( cd "${REPO_DIR}" && docker compose exec -T db psql -U "${user}" -d "${db}" -tAc \
      "select to_char(start_date,'YYYY-MM-DD') || ' ' || to_char(end_date,'YYYY-MM-DD') from public.site_visit where id = '${DEMO_SITE_VISIT_ID}'" 2>/dev/null ) \
    | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}
WINDOW="$(demo_window || true)"
VISIT_START="${WINDOW%% *}"
VISIT_END="${WINDOW##* }"
if [[ ! "${VISIT_START}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || ! "${VISIT_END}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  die "could not read the demo site visit's window from public.site_visit (id ${DEMO_SITE_VISIT_ID}).
         Seed the demo dataset first (re-run without --skip-seed)."
fi
ok "seeded demo site visit window: ${VISIT_START} -> ${VISIT_END}"

# ---------------------------------------------------------------------------
step "1b. Seed the demo identities (compliance_cmis)"
( cd "${WORKSPACE_ROOT}/compliance_cmis" && ./scripts/seed-demo-identities.sh --yes >/dev/null ) \
  || die "identity seeding failed"
ok "closure.reviewer (closure_reviewer) and demo.inspector1 (inspector) can log in"

# ---------------------------------------------------------------------------
if [[ "${SKIP_IMPORT}" == "0" ]]; then
  # Payloads are stamped into a scratch directory and imported from there, so the tracked
  # ZIPs stay pristine templates. The scratch copy is read by the host's curl, not by a
  # container, so a host /tmp path is fine here.
  PAYLOAD_DIR="${WORKSPACE_ROOT}/compliance_import/example data"
  STAMP_SCRIPT="${WORKSPACE_ROOT}/compliance_import/scripts/stamp-payload-window.py"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to stamp the demo payloads with the seeded window"
  [[ -f "${STAMP_SCRIPT}" ]] || die "${STAMP_SCRIPT} is missing — are the six repositories checked out side by side?"
  STAMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${STAMP_DIR}"' EXIT

  stamp_payload() { # stamp_payload <payload name> -> prints the stamped copy's path
    # Two statements, not one `local`: bash expands every word of a declaration before it
    # assigns any of them, so `local name="$1" destination="${STAMP_DIR}/${name}"` reads an
    # unset `name` (and `set -u` aborts).
    local name="$1"
    local destination="${STAMP_DIR}/${name}"
    if ! python3 "${STAMP_SCRIPT}" "${PAYLOAD_DIR}/${name}" "${destination}" \
        --start "${VISIT_START}" --end "${VISIT_END}" > "${STAMP_DIR}/${name}.log" 2>&1; then
      sed 's/^/    /' "${STAMP_DIR}/${name}.log" >&2
      die "could not stamp ${name} with the seeded window ${VISIT_START} -> ${VISIT_END}"
    fi
    # Both streams to stderr: stdout is the return value (the path), so the derivation the
    # script reports cannot be mistaken for it by the caller's command substitution.
    sed 's/^/    /' "${STAMP_DIR}/${name}.log" >&2
    printf '%s' "${destination}"
  }

  TICKET="$(ticket)" || die "could not obtain an Alfresco ticket (check ALFRESCO_USERNAME/PASSWORD in compliance_flow/.env)"
  ok "operator ticket acquired"

  step "2. Import the checklist + findings payload, stamped with the seeded window (compliance_import)"
  ATS_PAYLOAD="$(stamp_payload demo_inspection_payload.zip)"
  RESP=$(curl -s -m 240 -X POST "http://${DEMO_HOST}:8000/inspection-import" \
    -H "X-Alfresco-Ticket: ${TICKET}" \
    -F "file=@${ATS_PAYLOAD}")
  echo "    ${RESP}" | head -c 200; echo
  [[ "$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).status)}catch(e){console.log("")}})')" == "imported" ]] \
    || die "inspection-import failed: ${RESP}"
  ok "findings and evidence written to the canonical source folder"

  step "3. Import the canonical documents (compliance_cmis, query-param form)"
  RESP=$(curl -s -m 240 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d '{"inspectionCode":"AV-ZZZZ-A-0001","specialtyName":"Servicio de tránsito aéreo"}')
  echo "    ${RESP}" | head -c 200; echo
  SUCCESS=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).success===true)}catch(e){console.log(false)}})')
  [[ "${SUCCESS}" == "true" ]] || die "canonical import failed: ${RESP}"
  ok "documents moved into the inspection folder"

  # The demo dataset seeds two inspections — ATS and MET. Both need a payload, because the
  # inspection *window* lives on the Alfresco inspection folder (vso:startDate/vso:endDate),
  # which only exists once canonical documents have been imported for it; AtroCore's
  # `inspection` table has no date columns of its own. Without this the MET inspection is a bare
  # record that no provider-history report can date.
  step "2b. Import the MET checklist payload, stamped with the same window (compliance_import)"
  MET_PAYLOAD="$(stamp_payload demo_met_inspection_payload.zip)"
  RESP=$(curl -s -m 240 -X POST "http://${DEMO_HOST}:8000/inspection-import" \
    -H "X-Alfresco-Ticket: ${TICKET}" \
    -F "file=@${MET_PAYLOAD}")
  echo "    ${RESP}" | head -c 200; echo
  [[ "$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).status)}catch(e){console.log("")}})')" == "imported" ]] \
    || die "MET inspection-import failed: ${RESP}"
  ok "MET checklist and evidence written to the canonical source folder"

  step "3b. Import the MET canonical documents (compliance_cmis)"
  RESP=$(curl -s -m 240 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d '{"inspectionCode":"AV-ZZZZ-I-0001","specialtyName":"Meteorología aeronáutica"}')
  echo "    ${RESP}" | head -c 200; echo
  SUCCESS=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).success===true)}catch(e){console.log(false)}})')
  [[ "${SUCCESS}" == "true" ]] || die "MET canonical import failed: ${RESP}"
  ok "MET inspection folder created with its window (AV-ZZZZ-I-0001)"

  step "4. Import the follow-up, stamped after the window it reviews (compliance_import)"
  FOLLOWUP_PAYLOAD="$(stamp_payload demo_followup_payload.zip)"
  RESP=$(curl -s -m 240 -X POST "http://${DEMO_HOST}:8000/followup-import" \
    -H "X-Alfresco-Ticket: ${TICKET}" \
    -F "file=@${FOLLOWUP_PAYLOAD}")
  echo "    ${RESP}" | head -c 220; echo
  FOLLOW_UP_FILE=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).followUpFilenames||[""])[0])}catch(e){}})')
  [[ -n "${FOLLOW_UP_FILE}" ]] || die "followup-import failed: ${RESP}"
  ok "follow-up document: ${FOLLOW_UP_FILE}"

  step "5. Process the follow-up — this is what moves the finding (NOT step 3's form)"
  RESP=$(curl -s -m 240 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d "{\"inspectionCode\":\"AV-ZZZZ-A-0001\",\"specialtyName\":\"Servicio de tránsito aéreo\",\"followUpFiles\":[\"${FOLLOW_UP_FILE}\"]}")
  echo "    ${RESP}" | head -c 260; echo
  PENDING=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).summary||{}).pendingClosureApprovals||0)}catch(e){console.log(0)}})')
  [[ "${PENDING}" == "1" ]] || die "the follow-up was not processed (pendingClosureApprovals=${PENDING}); a moved-evidence re-run needs step 4 repeated"
  ok "finding H-ZZZZA0001-ATS-001 is now Pending Closure Approval"
else
  step "2-5. Importing skipped"
fi

# ---------------------------------------------------------------------------
step "6. Verify"
( cd "${WORKSPACE_ROOT}/compliance_flow" && node scripts/smoke-flows.mjs ) | tail -1 || die "smoke harness failed"
( cd "${WORKSPACE_ROOT}/compliance_flow" && node scripts/audit-error-envelope.mjs --enforce ) | tail -1 || die "error-envelope audit failed"
OPEN=$(curl -s -m 60 "http://${DEMO_HOST}:1880/findings/open?locationCode=ZZZZ&specialtyCode=ATS" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log("?")}})')
ok "open demo findings: ${OPEN}"

# A checklist item is dated by its nearest inspection ancestor, and the inspection window lives on
# the Alfresco folder (AtroCore's `inspection` table has no date columns), so both seeded
# inspections must carry one — and it must be the window the seed computed, or the demo's items
# fall outside the period its reports filter on.
for code in AV-ZZZZ-A-0001 AV-ZZZZ-I-0001; do
  WINDOW=$(curl -s -m 30 -u "${ALFRESCO_USERNAME}:${ALFRESCO_PASSWORD}" \
    "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-?relativePath=/Sites/vigilancia-de-la-so/documentLibrary/Vigilancia/Inspecciones/${code}&include=properties" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).entry.properties;const day=v=>v?String(v).slice(0,10):"none";console.log(day(p["vso:startDate"])+" -> "+day(p["vso:endDate"]))}catch(e){console.log("missing")}})')
  # `vso:startDate` is a `d:date`, so the API answers a full timestamp (`2026-10-07T00:00:00.000+0000`);
  # only the day is comparable with what the seed wrote into `site_visit.start_date`.
  case "${WINDOW}" in
    *none*|missing) die "${code} has no inspection window (${WINDOW})" ;;
  esac
  [[ "${WINDOW}" == "${VISIT_START} -> ${VISIT_END}" ]] \
    || die "${code}'s window (${WINDOW}) is not the seeded site visit's (${VISIT_START} -> ${VISIT_END}) — re-run without --skip-import to stamp the payloads onto the current seed"
  ok "${code} window: ${WINDOW} (matches the seeded site visit)"
done

# ---------------------------------------------------------------------------
if [[ "${SKIP_IMPORT}" == "0" ]]; then
  # -------------------------------------------------------------------------
  # The reporting half. Until this existed the quickstart populated the work products and ran
  # the read-only flow checks, but never produced a single oversight artifact — so the plan,
  # the inspection report, the provider history and the USOAP CE-evidence report could all
  # regress without anything here noticing.
  #
  # Two visits are involved (§7.2): the plan belongs to the visit that has not happened yet,
  # the report and history to the one that has.
  # -------------------------------------------------------------------------
  VISIT_PAST="V-ZZZZ-$(date +%Y)-01"
  VISIT_FUTURE="V-ZZZZ-$(date +%Y)-02"

  # The transform service is cold for the first call or two after a repository restart
  # ("PDF transformation failed"), so retry instead of reporting a false failure.
  retry_json() { # retry_json <attempts> <url>
    local attempt response=""
    for attempt in $(seq 1 "$1"); do
      response=$(curl -s -m 180 "$2")
      case "${response}" in
        *'"status": "success"'*|*'"status":"success"'*) printf '%s' "${response}"; return 0 ;;
      esac
      [ "${attempt}" -lt "$1" ] && sleep 10
    done
    printf '%s' "${response}"
  }

  # JSON arrives on stdin: the inspection report answers with ~1 MB (it echoes its input and
  # the rendered report data), which overflows an argv entry if it is passed as an argument.
  json_field() { # json_field <expression over `j`>  (JSON on stdin)
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(new Function("j","return ("+process.argv[1]+")")(j))}catch(e){console.log("")}})' "$1"
  }

  alfresco_node() { # alfresco_node <repository display path> -> "<id> <name>", or empty
    local relative encoded
    # The webscripts report a display path starting at /Company Home, which is exactly what the
    # nodes API calls `-root-`, so that prefix has to come off before it is used as a
    # relativePath (the API answers 404 otherwise).
    relative="${1#/Company Home}"
    encoded=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "${relative}")
    curl -s -m 30 -u "${ALFRESCO_USERNAME}:${ALFRESCO_PASSWORD}" \
      "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-?relativePath=${encoded}&include=properties" \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const e=JSON.parse(s).entry;console.log(e.id+" "+e.name)}catch(e){}})'
  }

  step "7. Generate the oversight artifacts (compliance_flow + compliance_cmis)"

  # 7a. Plan, on the visit that has not happened yet. This is also what moves the inspection
  #     from Assigned to Planned, which the last line of this step asserts.
  PLAN=$(retry_json 4 "http://${DEMO_HOST}:1880/inspectionPlan?siteVisit=${VISIT_FUTURE}&provider=demo-iprov-ans-02&locale=es")
  PLAN_PATH=$(printf '%s' "${PLAN}" | json_field 'j.generatedFile.path')
  [ -n "${PLAN_PATH}" ] || die "inspectionPlan failed: $(printf '%s' "${PLAN}" | head -c 200)"
  [ -n "$(alfresco_node "${PLAN_PATH}")" ] || die "the plan was reported at ${PLAN_PATH} but no such document exists"
  ok "plan filed: ${PLAN_PATH}"

  # 7b. Inspection report, on the visit that has happened.
  REPORT=$(retry_json 4 "http://${DEMO_HOST}:1880/inspectionReport?siteVisit=${VISIT_PAST}&provider=demo-prov-ans&locale=es")
  REPORT_PATH=$(printf '%s' "${REPORT}" | json_field 'j.generatedFile.path')
  [ -n "${REPORT_PATH}" ] || die "inspectionReport failed: $(printf '%s' "${REPORT}" | head -c 200)"
  [ -n "$(alfresco_node "${REPORT_PATH}")" ] || die "the report was reported at ${REPORT_PATH} but no such document exists"
  ok "inspection report filed: ${REPORT_PATH}"

  # 7c. Provider history. It filters by year, which is why a checklist item needs a dated
  #     inspection ancestor — a zero here means the inspection window is missing.
  HISTORY=$(curl -s -m 120 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/s/api/providers/provider-history-report?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d "{\"providerId\":\"demo-prov-ans\",\"year\":\"$(date +%Y)\"}")
  HISTORY_TOTAL=$(printf '%s' "${HISTORY}" | json_field 'j.summary.total')
  [ -n "${HISTORY_TOTAL}" ] || die "provider-history-report failed: $(printf '%s' "${HISTORY}" | head -c 200)"
  [ "${HISTORY_TOTAL%%.*}" -gt 0 ] 2>/dev/null \
    || die "the provider history for $(date +%Y) is empty — the inspection window or the imported dates are missing"
  ok "provider history for demo-prov-ans: ${HISTORY_TOTAL%%.*} artifacts (findings, checklist items, follow-ups)"

  # 7d. USOAP CE evidence report. Its artifacts are the chain tags the canonical import writes
  #     onto checklist items and findings, so a zero means the payload carried no reference and
  #     the documents imported untagged.
  CE=$(curl -s -m 120 -X POST \
    "http://${DEMO_HOST}:8080/alfresco/s/api/usoap/ce-evidence-report?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d "{\"ce\":\"CE-5\",\"year\":\"$(date +%Y)\",\"populationQueries\":[{\"pqCode\":\"PQ 99.001\",\"artifactCategory\":\"Checklist\",\"specialtyCode\":\"ATS\",\"monthsBack\":24}]}")
  CE_TOTAL=$(printf '%s' "${CE}" | json_field 'j.summary.total')
  CE_PQ=$(printf '%s' "${CE}" | json_field 'Object.keys(j.summary.byPq).join(",")')
  [ -n "${CE_TOTAL}" ] || die "ce-evidence-report failed: $(printf '%s' "${CE}" | head -c 200)"
  [ "${CE_TOTAL%%.*}" -gt 0 ] 2>/dev/null \
    || die "the CE-5 evidence report found no artifacts — the imported documents are not USOAP-tagged (did the payload keep its reference.usoapPqReference?)"
  ok "USOAP CE-5 evidence: ${CE_TOTAL%%.*} artifacts under ${CE_PQ:-?}, plus its gap analysis of missing evidence"

  ok "the planning walkthrough moved AV-ZZZZ-A-0002 to $(docker compose exec -T db psql -U "${POSTGRES_PIM_USER}" -d "${POSTGRES_PIM_DB}" -tAc "select status from inspection where code='AV-ZZZZ-A-0002'" | tr -d '[:space:]')"
else
  step "7. Reporting walkthrough skipped (it needs the imported work products)"
fi

# ---------------------------------------------------------------------------
step "Next: the closure review (identities are seeded in step 1b)"
cat <<'REVIEW'
    # log in as the reviewer and take the csrfToken from the response
    curl -c jar -X POST http://${DEMO_HOST}:4000/api/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"username":"closure.reviewer","password":"<pw>"}'

    # reject (a reason is required and is stored on the finding)
    curl -b jar -X PATCH "http://${DEMO_HOST}:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: <csrfToken>" \
      -d '{"decision":"reject","reason":"Closure evidence is undated"}'

    # approve (closes it, sets vso:findingClosureDate, clears any rejection reason)
    curl -b jar -X PATCH "http://${DEMO_HOST}:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: <csrfToken>" \
      -d '{"decision":"approve"}'
REVIEW

printf '\ndemo-quickstart: done\n'
