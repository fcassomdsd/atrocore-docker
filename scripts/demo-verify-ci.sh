#!/usr/bin/env bash
#
# demo-verify-ci.sh — bring the whole stack up from sibling checkouts and run the demo
# quickstart, so a change in any of the six repositories that breaks the demo fails a pipeline.
#
# Why this exists: the demo needs all six repositories side by side (the quickstart reads
# `../compliance_import/example data/`, `../compliance_flow/.env` and `../compliance_cmis`), but
# a GitLab job checks out exactly one. `atrocore-docker`'s `validate:fresh-install` therefore
# covers AtroCore and the three seeds and nothing else — the imports, the identities, the
# closure walkthrough and the oversight artifacts were only ever verified by hand.
#
# All six projects are public, so the other five are cloned over HTTPS at `$SIBLING_REF`
# (default `develop`, the integration branch).
#
# Usage:
#   demo-verify-ci.sh [--prepare-only]
#
#   --prepare-only   clone the siblings, write their .env files, create the docker networks and
#                    validate every compose file, then stop. Runs in seconds and is how this
#                    script's wiring is checked locally without starting a second stack.
#
# Environment:
#   SIBLING_REF       branch to clone (default: develop)
#   DEMO_WORKSPACE    where the sibling layout lives (default: the checkout's parent directory —
#                     which on GitLab CI is under /builds, the one place the docker daemon can
#                     also see; a /tmp workspace would be invisible to it)
#   GITLAB_HOST       git host for the clones (default: gitlab.com)
#
set -euo pipefail

PREPARE_ONLY=0
TEARDOWN_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --prepare-only) PREPARE_ONLY=1 ;;
    --teardown) TEARDOWN_ONLY=1 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

SIBLING_REF="${SIBLING_REF:-develop}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"

# The quickstart needs these, and a missing one otherwise fails several minutes in, deep inside a
# demo step with an opaque message (`node: command not found` after the app is installed and the
# dataset seeded). Check up front.
for tool in docker curl python3 node git; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "demo-verify-ci: '${tool}' is required (runbook §1.1 lists the host prerequisites)" >&2
    exit 1
  }
done

# On a CI runner the published ports live on the dind service, not on this container's own
# localhost, so every service URL is built from this. The quickstart takes it as DEMO_HOST for
# exactly that reason; ATROCORE_BASE_URL and ALFRESCO_URL are what the scripts it calls read.
if [[ -n "${CI:-}" && -z "${DEMO_HOST:-}" ]]; then
  export DEMO_HOST=docker
else
  export DEMO_HOST="${DEMO_HOST:-localhost}"
fi
# ATROCORE_BASE_URL and ALFRESCO_URL are deliberately NOT exported here: `docker compose` reads
# the shell environment for its own interpolation, so exporting a host-reachable address would put
# it inside the containers, where `docker` (the dind alias) does not resolve. The quickstart passes
# the host-facing values to the two commands that need them; the containers keep the in-network
# addresses from their .env files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The docker daemon (the dind service in CI) resolves bind mounts on its own filesystem, so the
# workspace must be somewhere it can see: the checkout's parent is under /builds and shared with
# it, a /tmp path is not.
if [[ -n "${DEMO_WORKSPACE:-}" ]]; then
  WORKSPACE="${DEMO_WORKSPACE}"
elif [[ -n "${CI_PROJECT_DIR:-}" ]]; then
  WORKSPACE="$(cd "${CI_PROJECT_DIR}/.." && pwd)"
else
  WORKSPACE="$(cd "${REPO_DIR}/.." && pwd)"
fi
mkdir -p "${WORKSPACE}"

step() { printf '\n=== %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
die()  { printf '    FAIL %s\n' "$1" >&2; exit 1; }

# A failing `compose up` says "dependency failed to start: container X is unhealthy" and nothing
# else, which is not enough to fix anything from a CI log. Dump the project's container states and
# the tail of the ones that are not healthy.
diagnose() { # diagnose <project dir>
  local dir="$1" prefix name status
  prefix="$(basename "${dir}")"
  printf '    --- %s container states\n' "${prefix}"
  docker ps -a --format '{{.Names}}	{{.Status}}' | grep -E "^${prefix}-" | sed 's/^/      /' || true
  docker ps -a --format '{{.Names}}	{{.Status}}' | grep -E "^${prefix}-" \
    | grep -iE "unhealthy|exited|restarting|dead" | cut -f1 | while read -r name; do
      # 200 lines, and grep out the first "Caused by" chain: a container that never becomes
      # healthy usually fails hundreds of lines above its last line, and the tail is the only
      # place a CI log can show it.
      printf '    --- %s: how it failed\n' "${name}"
      docker logs --tail 200 "${name}" 2>&1 \
        | grep -nE "Caused by|Error creating bean|SEVERE|OutOfMemory|Killed|Cannot allocate|No space left" \
        | tail -10 | sed 's/^/      /' || true
      printf '    --- %s: last 15 lines\n' "${name}"
      docker logs --tail 15 "${name}" 2>&1 | sed 's/^/      /' || true
    done
}

# project path -> directory the quickstart expects to find it in
SIBLINGS=(
  "safety-app2/compliance-cmis:compliance_cmis"
  "safety-app2/compliance_flow:compliance_flow"
  "safety-app2/compliance_import:compliance_import"
  "safety-app2/compliance_web:compliance_web"
  "safety-app2/compliance_app:compliance_checklist"
)

# ---------------------------------------------------------------------------
step "1. Sibling checkouts under ${WORKSPACE}"
# ---------------------------------------------------------------------------
if [[ "$(cd "${REPO_DIR}" && pwd)" != "${WORKSPACE}/atrocore-docker" ]]; then
  # In CI the checkout is named after the project; the quickstart only cares that the siblings
  # are next to it, so nothing is moved.
  ok "using the checkout at ${REPO_DIR} as atrocore-docker"
fi

for entry in "${SIBLINGS[@]}"; do
  project="${entry%%:*}"
  target="${WORKSPACE}/${entry##*:}"
  if [[ -d "${target}/.git" ]]; then
    ( cd "${target}" && git fetch --depth 1 origin "${SIBLING_REF}" >/dev/null 2>&1 \
        && git checkout -q FETCH_HEAD ) || die "could not update ${target} to ${SIBLING_REF}"
    ok "${entry##*:} (updated to ${SIBLING_REF})"
  else
    rm -rf "${target}"
    git clone -q --depth 1 --single-branch --branch "${SIBLING_REF}" \
      "https://${GITLAB_HOST}/${project}.git" "${target}" \
      || die "could not clone ${project} at ${SIBLING_REF}"
    ok "${entry##*:} (cloned ${project} at ${SIBLING_REF})"
  fi
done

# ---------------------------------------------------------------------------
step "2. Environment files"
#
# The values are the local demo's, not secrets: this runs a throwaway stack. Anything a service
# refuses to start without is set explicitly, because most examples ship "replace-me".
# ---------------------------------------------------------------------------
# The sibling checkouts are throwaway, so their .env files are seeded from the examples and the
# values a service refuses to start without are then merged in. Existing keys are replaced and
# every other line is left alone, so a developer running this locally keeps their own settings.
ensure_env() { # ensure_env <repo dir> <example file> <<< "VAR=value" lines
  local dir="$1" example="$2" additions
  additions="$(cat)"
  if [[ ! -f "${dir}/.env" ]]; then
    [[ -f "${dir}/${example}" ]] || die "${dir}/${example} is missing"
    cp "${dir}/${example}" "${dir}/.env" || die "cannot seed ${dir}/.env"
  fi
  MERGE_ENV_ADDITIONS="${additions}" python3 - "${dir}/.env" <<'PY'
import os
import sys

path = sys.argv[1]
wanted = {}
for raw in os.environ.get("MERGE_ENV_ADDITIONS", "").splitlines():
    if raw.strip() and not raw.strip().startswith("#"):
        key, _, value = raw.partition("=")
        wanted[key] = value

out, seen = [], set()
for raw in open(path, encoding="utf-8").read().splitlines():
    key = raw.split("=", 1)[0] if "=" in raw else None
    if key in wanted:
        if key not in seen:
            out.append(key + "=" + wanted[key])
            seen.add(key)
        continue
    out.append(raw)
for key, value in wanted.items():
    if key not in seen:
        out.append(key + "=" + value)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  ok "$(basename "${dir}")/.env ready"
}

# atrocore-docker's own .env is deliberately NOT written here: CI's before_script already creates
# it from the pipeline variables, and a developer running this locally has one they would not want
# rewritten.
[[ -f "${REPO_DIR}/.env" ]] || die "${REPO_DIR}/.env is missing (CI writes it in before_script; locally copy .env.example)"
ok "atrocore-docker/.env present (left untouched)"

# AtroCore is installed by the quickstart with these credentials, and the flow uses the same
# pair to reach its API.
ensure_env "${WORKSPACE}/compliance_flow" .env.example <<'EOF'
ALFRESCO_USERNAME=admin
ALFRESCO_PASSWORD=admin
ATROCORE_USERNAME=ci_admin
ATROCORE_PASSWORD=ci_admin_password
ADMIN_USERNAME=admin
# bcrypt hash (of "password"), a throwaway editor login the demo never uses. Compose
# interpolates `$` in .env files, so each one is escaped as `$$`.
ADMIN_PASSWORD_HASH=$$2a$$10$$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy
NODE_RED_CREDENTIAL_SECRET=ci_node_red_credential_secret
NODE_ENV=development
ATROCORE_BASE_URL=http://atro-web/api/v1
ALFRESCO_BASE_URL=http://proxy:8080/alfresco
EOF

ensure_env "${WORKSPACE}/compliance_import" .env.docker.example <<'EOF'
ALFRESCO_URL=http://proxy:8080/alfresco/api/-default-/public/alfresco/versions/1
ALFRESCO_CANONICAL_JSON_PATH=Sites/vigilancia-de-la-so/documentLibrary/Vigilancia/Datos de campo
EOF
mkdir -p "${WORKSPACE}/compliance_import/docker/secrets"
printf 'admin' > "${WORKSPACE}/compliance_import/docker/secrets/alfresco_username.txt"
printf 'admin' > "${WORKSPACE}/compliance_import/docker/secrets/alfresco_password.txt"
ok "compliance_import Alfresco credential files written"

ensure_env "${WORKSPACE}/compliance_web" .env.docker.example <<'EOF'
POSTGRES_DB=compliance
POSTGRES_USER=compliance
POSTGRES_PASSWORD=ci_compliance_password
ALFRESCO_BASE_URL=http://proxy:8080
AUTH_TICKET_ENCRYPTION_KEY=ci_ticket_encryption_key_0123456789
AUTH_NODE_ENV=development
AUTH_COOKIE_SECURE=false
EOF

ensure_env "${WORKSPACE}/compliance_cmis" .env.example <<'EOF'
DB_PASSWORD=alfresco
SOLR_SECRET=secret
SERVER_NAME=localhost
EOF

# ---------------------------------------------------------------------------
step "3. Docker networks"
#
# Nothing is created here on purpose. Each network is *declared* by one project and marked
# external by the others, so it has to be created by the project that owns it — creating
# `backend_net` by hand makes atrocore-docker refuse to start with "a network with name
# backend_net exists but was not created by compose". Bringing the projects up in dependency
# order is what creates them:
#
#   backend_net      atrocore-docker (declared as backend_ext_net)
#   alfresco_backend compliance_cmis
#   import-backend   compliance_import
#
# compliance_flow and compliance_web then attach to all three as externals.
ok "left to the projects that declare them (see step 5)"

# ---------------------------------------------------------------------------
step "4. Compose files"
# ---------------------------------------------------------------------------
( cd "${REPO_DIR}" && docker compose config --quiet ) || die "atrocore-docker compose is invalid"
ok "atrocore-docker"
( cd "${WORKSPACE}/compliance_cmis" && docker compose config --quiet ) || die "compliance_cmis compose is invalid"
ok "compliance_cmis"
( cd "${WORKSPACE}/compliance_import" && docker compose config --quiet ) || die "compliance_import compose is invalid"
ok "compliance_import"
( cd "${WORKSPACE}/compliance_flow" && docker compose config --quiet ) || die "compliance_flow compose is invalid"
ok "compliance_flow"
( cd "${WORKSPACE}/compliance_web" \
    && docker compose -f docker-compose.yml -f docker-compose.dev.yml config --quiet ) \
  || die "compliance_web compose (dev override) is invalid"
ok "compliance_web (dev override)"

# Everything from here needs the stack, and the teardown mode only takes it down.
if [[ "${TEARDOWN_ONLY}" == "1" ]]; then
  step "Teardown"
  for dir in "${WORKSPACE}/compliance_web" "${WORKSPACE}/compliance_flow" \
             "${WORKSPACE}/compliance_import" "${WORKSPACE}/compliance_cmis" "${REPO_DIR}"; do
    [[ -d "${dir}" ]] || continue
    ( cd "${dir}" && docker compose -f docker-compose.yml down -v --remove-orphans >/dev/null 2>&1 ) || true
    ( cd "${dir}" && docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev down -v --remove-orphans >/dev/null 2>&1 ) || true
    ( cd "${dir}" && docker compose down -v --remove-orphans >/dev/null 2>&1 ) || true
    ok "$(basename "${dir}") down"
  done
  for network in backend_net alfresco_backend import-backend; do
    docker network rm "${network}" >/dev/null 2>&1 || true
  done
  ok "networks removed"
  printf '\ndemo-verify-ci: torn down\n'
  exit 0
fi

if [[ "${PREPARE_ONLY}" == "1" ]]; then
  printf '\ndemo-verify-ci: prepared only (no containers started)\n'
  exit 0
fi

# ---------------------------------------------------------------------------
step "5. Bring the stack up"
#
# Order matters (runbook §2): AtroCore, then Alfresco, then the import service, then the flow,
# then the web app. `COMPOSE_BAKE=false DOCKER_BUILDKIT=0` is for runners without buildx.
# ---------------------------------------------------------------------------
compose_up() { # compose_up <dir> [service ...]
  local dir="$1"; shift
  local name; name="$(basename "${dir}")"
  # `-f`/`--profile` are global flags and must come before the subcommand; `--no-deps` belongs to
  # `up` and must come after it.
  local -a global_args=() up_args=()
  # compliance_web is the one project whose services are not all in the base file: the backend's
  # published port and the UI live in the dev override and the `dev` profile (runbook §5.5).
  if [[ "${name}" == "compliance_web" ]]; then
    global_args=(-f docker-compose.yml -f docker-compose.dev.yml --profile dev)
  fi
  # compliance_cmis is started with --no-deps: Alfresco takes minutes to report healthy and
  # compose treats "unhealthy within the start period" as a hard failure of the whole `up`, which
  # on a cold runner aborts before the stack has had a chance. The wait_for probes below are the
  # real gate and poll far longer than compose would.
  if [[ "${name}" == "compliance_cmis" ]]; then
    up_args=(--no-deps)
  fi
  ( cd "${dir}" && COMPOSE_BAKE=false DOCKER_BUILDKIT=0 \
      docker compose "${global_args[@]}" up -d --build "${up_args[@]}" "$@" ) \
    || { diagnose "${dir}"; die "compose up failed in ${dir}"; }
  ok "${name} up"
}

compose_up "${REPO_DIR}" db atro-web
# The Alfresco content store lives in a bind mount that is gitignored, so a fresh checkout does
# not have it and the container cannot create it (compliance_cmis/scripts/bootstrap-alf-data.sh
# has the whole failure). Without this the repository webapp never deploys and `compose up` fails
# with "dependency failed to start: container … is unhealthy".
( cd "${WORKSPACE}/compliance_cmis" && ./scripts/bootstrap-alf-data.sh ) \
  || die "could not prepare the Alfresco content store"
compose_up "${WORKSPACE}/compliance_cmis"
compose_up "${WORKSPACE}/compliance_import"
# Node-RED runs as uid 1000 and writes node_modules into its bind-mounted data/ directory; on a
# checkout owned by anyone else it exits with EACCES and the port never answers (see
# compliance_flow/scripts/bootstrap-node-red-data.sh).
( cd "${WORKSPACE}/compliance_flow" && ./scripts/bootstrap-node-red-data.sh ) \
  || die "could not prepare the Node-RED data directory"
compose_up "${WORKSPACE}/compliance_flow"
compose_up "${WORKSPACE}/compliance_web"

wait_for_any_http() { # wait_for_any_http <label> <url> <attempts> [container name prefix]
  local label="$1" url="$2" attempts="$3" prefix="${4:-}" i code
  for i in $(seq 1 "${attempts}"); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${url}" 2>/dev/null || true)
    if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
      ok "${label} is serving (${code} after ${i})"
      return 0
    fi
    sleep 5
  done
  if [[ -n "${prefix}" ]]; then
    docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E "^${prefix}" | sed 's/^/      /' || true
    for container in $(docker ps -a --format '{{.Names}}' | grep -E "^${prefix}" || true); do
      printf '    --- last 30 log lines of %s\n' "${container}"
      docker logs --tail 30 "${container}" 2>&1 | sed 's/^/      /' || true
    done
  fi
  die "${label} is not serving (last HTTP ${code:-none}) — see runbook §8"
}

wait_for() { # wait_for <label> <url> <acceptable codes> <attempts> [container name prefix]
  local label="$1" url="$2" acceptable="$3" attempts="$4" prefix="${5:-}" i code
  for i in $(seq 1 "${attempts}"); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${url}" 2>/dev/null || true)
    case "${acceptable}" in
      *"${code}"*) ok "${label} (${code} after ${i})"; return 0 ;;
    esac
    sleep 5
  done
  # A service that never answers has usually crashed, and `docker compose up -d` does not fail on
  # a container that starts and then exits — so print what it said before giving up.
  if [[ -n "${prefix}" ]]; then
    printf '    --- containers matching %s\n' "${prefix}"
    docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E "^${prefix}" | sed 's/^/      /' || true
    local container
    for container in $(docker ps -a --format '{{.Names}}' | grep -E "^${prefix}" || true); do
      printf '    --- last 30 log lines of %s\n' "${container}"
      docker logs --tail 30 "${container}" 2>&1 | sed 's/^/      /' || true
    done
  fi
  die "${label} did not answer (last HTTP ${code:-none}) — see runbook §8"
}

# AtroCore answers 404 here, not 200/401: on a clean checkout web-data/ is an empty bind mount, so
# Apache has no DocumentRoot until the quickstart's step 0b copies the application out of the image
# — and the quickstart probes it properly once that has happened. The readiness signal this script
# needs is therefore "the web server answers at all". (The quickstart's own preflight skips this
# probe for exactly the same reason.)
wait_for_any_http "AtroCore" "http://${DEMO_HOST}/api/v1/App/user" 60 "compliance_atrocore-"
wait_for "Alfresco"  "http://${DEMO_HOST}:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-" "200" 150 "compliance_cmis-"
wait_for "import"    "http://${DEMO_HOST}:8000/health" "200" 40 "compliance_import-"
wait_for "Node-RED"  "http://${DEMO_HOST}:1880/" "200 401" 40 "compliance_flow-"
wait_for "web API"   "http://${DEMO_HOST}:4000/health" "200" 60 "compliance_web-"

# ---------------------------------------------------------------------------
step "6. The demo itself"
# ---------------------------------------------------------------------------
( cd "${REPO_DIR}" && ./scripts/demo-quickstart.sh --yes ) || die "the demo quickstart failed"

printf '\ndemo-verify-ci: the whole-stack demo ran green\n'
