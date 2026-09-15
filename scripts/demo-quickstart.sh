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
# NOTE for a truly clean clone: the tracked metadata/ tree is a *partial overlay*
# (13 of the 32 entity definitions the running instance has — see metadata/README.md,
# "Only the files this project actually customises are tracked here"). The operational
# entities the demo seeds write to — Location, ServiceProvider, SiteVisit, Inspector,
# ServiceArea, Finding … — come from a provisioned `atrocore.dump`, not from this
# repository. The preflight below therefore stops before step 0b unless
# `public.service_area` exists, and prints the restore command; set
# SCHEMA_PROBE_TABLE to another table to exercise that failure path deliberately.
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
  3. run the read-only smoke harness and the error-envelope audit

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
step "0. Preflight — every service must answer before anything is seeded"
# ---------------------------------------------------------------------------
probe() { # probe <label> <url> <acceptable>
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$2" 2>/dev/null || true)
  case "$3" in
    *"$code"*) ok "$1 (:${2##*:} -> $code)" ;;
    *) die "$1 did not answer (HTTP ${code:-none}) — is the stack up? see runbook §5" ;;
  esac
}
probe "AtroCore"        "http://localhost/api/v1/App/user" "401"
probe "Alfresco"        "http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-" "200"
probe "Node-RED"        "http://localhost:1880/specialties" "200"
probe "import service"  "http://127.0.0.1:8000/health" "200"
probe "web backend"     "http://127.0.0.1:4000/health" "200"

# The operational schema is NOT built from this repository: the tracked metadata/ tree
# is a partial overlay (13 of the 32 entity definitions a provisioned instance carries —
# see metadata/README.md), so Location / ServiceProvider / SiteVisit / ServiceArea / …
# only exist after a provisioned `atrocore.dump` is restored. Fail here, with the remedy,
# rather than four steps later inside the seed scripts.
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
if schema_ready; then
  ok "operational schema present (public.${SCHEMA_PROBE_TABLE})"
else
  die "the AtroCore database has no operational schema (public.${SCHEMA_PROBE_TABLE} is missing).
         The tracked metadata/ tree is a partial overlay, so a clean clone must first restore a
         provisioned atrocore.dump: ./scripts/seed-demo-db.sh <dump-file> --yes
         (see README 'Restoring a real dataset' and runbook §7.2). If the stack is still
         starting, wait for PostgreSQL and re-run."
fi

set -a
# shellcheck disable=SC1091
. "${WORKSPACE_ROOT}/compliance_flow/.env"
set +a

ticket() {
  curl -s -m 30 -X POST \
    "http://localhost:8080/alfresco/api/-default-/public/authentication/versions/1/tickets" \
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
  ( cd "${REPO_DIR}" \
    && ./scripts/bootstrap-web-data.sh \
    && ./scripts/install-metadata.sh >/dev/null \
    && docker compose exec -T atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" clear cache >/dev/null \
    && docker compose exec -T atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" sql diff --run >/dev/null ) \
    || die "metadata install failed (see docs/COMPLIANCE_INTEGRATION_RUNBOOK.md §7.2)"
  ok "metadata installed into web-data/, cache cleared, schema synced"
else
  step "0b. Metadata install skipped"
fi

# ---------------------------------------------------------------------------
if [[ "${SKIP_SEED}" == "0" ]]; then
  step "1. Seed the reference catalogs and the demo dataset (atrocore-docker)"
  ( cd "${REPO_DIR}" \
    && ./scripts/seed-usoap-vocabularies.sh --yes >/dev/null \
    && ./scripts/seed-nomenclatura.sh --yes >/dev/null \
    && ./scripts/seed-demo-dataset.sh --yes >/dev/null ) \
    || die "seeding failed"
  ( cd "${REPO_DIR}" && docker compose exec -T atro-web php "/var/www/${ATROCORE_DOMAIN}/console.php" clear cache >/dev/null 2>&1 ) || true
  ok "82 demo rows across 25 tables (airport ZZZZ, 2 providers, 3 inspectors, 2 inspections, 9 questions + USOAP chain)"
else
  step "1. Seeding skipped"
fi

# ---------------------------------------------------------------------------
step "1b. Seed the demo identities (compliance_cmis)"
( cd "${WORKSPACE_ROOT}/compliance_cmis" && ./scripts/seed-demo-identities.sh --yes >/dev/null ) \
  || die "identity seeding failed"
ok "closure.reviewer (closure_reviewer) and demo.inspector1 (inspector) can log in"

# ---------------------------------------------------------------------------
if [[ "${SKIP_IMPORT}" == "0" ]]; then
  TICKET="$(ticket)" || die "could not obtain an Alfresco ticket (check ALFRESCO_USERNAME/PASSWORD in compliance_flow/.env)"
  ok "operator ticket acquired"

  step "2. Import the checklist + findings payload (compliance_import)"
  RESP=$(curl -s -m 240 -X POST "http://127.0.0.1:8000/inspection-import" \
    -H "X-Alfresco-Ticket: ${TICKET}" \
    -F "file=@${WORKSPACE_ROOT}/compliance_import/example data/demo_inspection_payload.zip")
  echo "    ${RESP}" | head -c 200; echo
  [[ "$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).status)}catch(e){console.log("")}})')" == "imported" ]] \
    || die "inspection-import failed: ${RESP}"
  ok "findings and evidence written to the canonical source folder"

  step "3. Import the canonical documents (compliance_cmis, query-param form)"
  RESP=$(curl -s -m 240 -X POST \
    "http://localhost:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=${TICKET}" \
    -H 'Content-Type: application/json' \
    -d '{"inspectionCode":"AV-ZZZZ-A-0001","specialtyName":"Servicio de tránsito aéreo"}')
  echo "    ${RESP}" | head -c 200; echo
  SUCCESS=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).success===true)}catch(e){console.log(false)}})')
  [[ "${SUCCESS}" == "true" ]] || die "canonical import failed: ${RESP}"
  ok "documents moved into the inspection folder"

  step "4. Import the follow-up (compliance_import)"
  RESP=$(curl -s -m 240 -X POST "http://127.0.0.1:8000/followup-import" \
    -H "X-Alfresco-Ticket: ${TICKET}" \
    -F "file=@${WORKSPACE_ROOT}/compliance_import/example data/demo_followup_payload.zip")
  echo "    ${RESP}" | head -c 220; echo
  FOLLOW_UP_FILE=$(printf '%s' "${RESP}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).followUpFilenames||[""])[0])}catch(e){}})')
  [[ -n "${FOLLOW_UP_FILE}" ]] || die "followup-import failed: ${RESP}"
  ok "follow-up document: ${FOLLOW_UP_FILE}"

  step "5. Process the follow-up — this is what moves the finding (NOT step 3's form)"
  RESP=$(curl -s -m 240 -X POST \
    "http://localhost:8080/alfresco/s/api/inspection/import-canonical?alf_ticket=${TICKET}" \
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
OPEN=$(curl -s -m 60 "http://localhost:1880/findings/open?locationCode=ZZZZ&specialtyCode=ATS" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log("?")}})')
ok "open demo findings: ${OPEN}"

# ---------------------------------------------------------------------------
step "Next: the closure review (identities are seeded in step 1b)"
cat <<'REVIEW'
    # log in as the reviewer and take the csrfToken from the response
    curl -c jar -X POST http://127.0.0.1:4000/api/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"username":"closure.reviewer","password":"<pw>"}'

    # reject (a reason is required and is stored on the finding)
    curl -b jar -X PATCH "http://127.0.0.1:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: <csrfToken>" \
      -d '{"decision":"reject","reason":"Closure evidence is undated"}'

    # approve (closes it, sets vso:findingClosureDate, clears any rejection reason)
    curl -b jar -X PATCH "http://127.0.0.1:4000/api/findings/H-ZZZZA0001-ATS-001/closure-review" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: <csrfToken>" \
      -d '{"decision":"approve"}'
REVIEW

printf '\ndemo-quickstart: done\n'
