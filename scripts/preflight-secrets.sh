#!/usr/bin/env bash
#
# preflight-secrets.sh — refuse to call a deployment "production" while it is
# still running on credentials that are published in these repositories.
#
# The platform ships working demo credentials on purpose: a shared gateway API
# key, an Alfresco database password of "alfresco", a Solr shared secret of
# "secret", and two demo identities. That is what makes a clean clone
# demonstrable in one pass. It is also the single most likely way this platform
# gets compromised, because every one of those values is in git and the demo
# path and the real path are otherwise the same commands.
#
# This script is the seam between the two. It is deliberately profile-aware:
#
#   --profile demo        (default) the published values are expected. Prints
#                         them back as a warning and exits 0, so the demo and
#                         demo:verify keep working unchanged.
#   --profile production  every published value is a hard failure, along with
#                         the structural mistakes that make a deployment
#                         insecure without looking wrong.
#
# It reads .env files only: no Docker daemon, no running stack, no network. So
# it can run in CI, in a deploy pipeline, or on a laptop before `compose up`.
#
# Exit 0 = the profile's expectations are met. Exit 1 = do not deploy this.

set -uo pipefail

PROFILE="demo"
WORKSPACE=""

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Usage: $0 [--profile demo|production] [--workspace DIR]"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --production) PROFILE="production"; shift ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --workspace=*) WORKSPACE="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

case "$PROFILE" in
  demo|production) ;;
  *) echo "Unknown profile '$PROFILE' (expected 'demo' or 'production')" >&2; exit 1 ;;
esac

# Default the workspace to the directory holding the six component repos,
# i.e. the parent of this repository.
if [ -z "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

FAILURES=0
WARNINGS=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }
warn() { yellow "  warn  $*"; WARNINGS=$((WARNINGS + 1)); }
pass() { green "  ok    $*"; }

# ---------------------------------------------------------------------------
# Values published in these repositories. Every one of these is in git, so
# anyone who has cloned any component repo already knows it.
#
# Keep this list in sync with the three services' own rejection lists:
#   compliance_flow/data/secrets.js         PUBLIC_PLACEHOLDERS
#   compliance_web/server/config/secrets.cjs PUBLIC_PLACEHOLDERS
#   compliance_import/secret_config.py      PUBLIC_PLACEHOLDERS
# Each service refuses these at startup; this script catches them earlier, and
# catches the ones no service validates (the database passwords).
# ---------------------------------------------------------------------------
PUBLISHED_VALUES=(
  "demo-only-CHANGE-BEFORE-ANY-PUBLIC-DEPLOYMENT"
  "dev-only-ticket-encryption-key-change-me"
  "change-me-for-non-dev"
  "replace-with-a-bcrypt-hash"
  "DemoInspector#2026"
  "DemoReviewer#2026"
  "a-secret-key"
  "mp6yc0UD9e"
  "oKIWzVdEdA"
  "replace-me"
  "change-me"
  "changeme"
  "alfresco"
  "password"
  "secret"
  "admin"
)

# repo:variable pairs that must hold a real value in production.
REQUIRED_PRODUCTION=(
  "compliance_flow:API_KEY"
  "compliance_flow:ALFRESCO_USERNAME"
  "compliance_flow:ALFRESCO_PASSWORD"
  "compliance_flow:ATROCORE_USERNAME"
  "compliance_flow:ATROCORE_PASSWORD"
  "compliance_flow:NODE_RED_CREDENTIAL_SECRET"
  "compliance_flow:ADMIN_PASSWORD_HASH"
  "compliance_web:AUTH_TICKET_ENCRYPTION_KEY"
  "compliance_web:POSTGRES_PASSWORD"
  "compliance_web:NODE_RED_API_KEY"
  "compliance_import:IMPORT_API_KEY"
  "compliance_cmis:DB_PASSWORD"
  "compliance_cmis:SOLR_SECRET"
  "compliance_cmis:METADATA_KEYSTORE_PASSWORD"
  "compliance_cmis:METADATA_KEYSTORE_METADATA_PASSWORD"
  "atrocore-docker:POSTGRES_PASSWORD"
  "atrocore-docker:POSTGRES_PIM_PASSWORD"
)

env_file_for() {
  local repo="$1" dir="${WORKSPACE}/$1"
  [ -d "$dir" ] || return 1
  for candidate in "$dir/.env" "$dir/.env.docker"; do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

# Read one variable from a .env file. Prints the value (may be empty).
# Deliberately not `source`: a .env is data, and sourcing it would execute it.
read_env_var() {
  local file="$1" name="$2"
  sed -n "s/^[[:space:]]*${name}=//p" "$file" 2>/dev/null \
    | tail -n 1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
    | sed -e 's/[[:space:]]*$//'
}

is_published_value() {
  local value="$1"
  for published in "${PUBLISHED_VALUES[@]}"; do
    [ "$value" = "$published" ] && return 0
  done
  return 1
}

# Whether a variable name denotes a credential rather than configuration.
#
# The distinction matters: ALFRESCO_PASSWORD=admin is a deployment-stopping
# problem, while ADMIN_USERNAME=admin is a default account name — worth
# pointing out, but not a secret, and failing a deploy over it would train
# people to pass --profile demo to get past the check.
is_secret_name() {
  case "$1" in
    *PASSWORD*|*SECRET*|*_KEY|*_KEY_*|API_KEY*|*HASH*|*TOKEN*|*DATABASE_URL*) return 0 ;;
    *) return 1 ;;
  esac
}

REPOS=(atrocore-docker compliance_cmis compliance_flow compliance_import compliance_web)

bold "preflight-secrets — profile: ${PROFILE}"
echo "workspace: ${WORKSPACE}"
echo

# ---------------------------------------------------------------------------
bold "Environment files"
# ---------------------------------------------------------------------------
declare -A ENV_FILES=()
for repo in "${REPOS[@]}"; do
  if file="$(env_file_for "$repo")"; then
    ENV_FILES["$repo"]="$file"
    pass "${repo} → $(basename "$file")"
  elif [ ! -d "${WORKSPACE}/${repo}" ]; then
    warn "${repo} is not checked out at ${WORKSPACE} — skipping its checks"
  elif [ "$PROFILE" = "production" ]; then
    fail "${repo} has no .env — a production deployment cannot rely on defaults"
  else
    warn "${repo} has no .env (fine before the first `cp .env.example .env`)"
  fi
done

# ---------------------------------------------------------------------------
bold "Secrets must not be tracked by git"
# ---------------------------------------------------------------------------
# P0 purged these from history. This is the regression guard: a re-added .env
# would put live credentials back into a public repository.
for repo in "${REPOS[@]}"; do
  dir="${WORKSPACE}/${repo}"
  [ -d "$dir/.git" ] || continue
  tracked="$(git -C "$dir" ls-files -- '.env' '.env.docker' 'data/flows_cred.json' 2>/dev/null)"
  if [ -n "$tracked" ]; then
    fail "${repo} tracks secret files in git: $(echo "$tracked" | tr '\n' ' ')"
  else
    pass "${repo} tracks no .env / credential file"
  fi
done

# ---------------------------------------------------------------------------
bold "Published values"
# ---------------------------------------------------------------------------
FOUND_PUBLISHED=0
for repo in "${!ENV_FILES[@]}"; do
  file="${ENV_FILES[$repo]}"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    name="${line%%=*}"
    name="$(echo "$name" | tr -d '[:space:]')"
    value="$(read_env_var "$file" "$name")"
    [ -z "$value" ] && continue
    if is_published_value "$value"; then
      FOUND_PUBLISHED=$((FOUND_PUBLISHED + 1))
      if [ "$PROFILE" != "production" ]; then
        warn "${repo}: ${name} is a published demo value"
      elif is_secret_name "$name"; then
        fail "${repo}: ${name} is set to a credential published in this repository"
      else
        warn "${repo}: ${name} is a published default (not a credential — review, but not blocking)"
      fi
    fi
  done < "$file"
done

if [ "$FOUND_PUBLISHED" -eq 0 ]; then
  pass "no published value is in use"
fi

# ---------------------------------------------------------------------------
if [ "$PROFILE" = "production" ]; then
# ---------------------------------------------------------------------------
  bold "Required secrets are set"
  for entry in "${REQUIRED_PRODUCTION[@]}"; do
    repo="${entry%%:*}"; name="${entry#*:}"
    file="${ENV_FILES[$repo]:-}"
    [ -n "$file" ] || continue
    value="$(read_env_var "$file" "$name")"
    if [ -z "$value" ]; then
      fail "${repo}: ${name} is unset or empty"
    else
      pass "${repo}: ${name} is set"
    fi
  done

  bold "The three gateway keys must match"
  # compliance_checklist holds a fourth copy, entered in the app, which this
  # script cannot see — it is called out in the summary instead.
  flow_key="$(read_env_var "${ENV_FILES[compliance_flow]:-/dev/null}" API_KEY)"
  web_key="$(read_env_var "${ENV_FILES[compliance_web]:-/dev/null}" NODE_RED_API_KEY)"
  import_key="$(read_env_var "${ENV_FILES[compliance_import]:-/dev/null}" IMPORT_API_KEY)"
  if [ -z "$flow_key" ] || [ -z "$web_key" ] || [ -z "$import_key" ]; then
    fail "one or more gateway keys is unset (flow/web/import)"
  elif [ "$flow_key" = "$web_key" ] && [ "$web_key" = "$import_key" ]; then
    pass "API_KEY, NODE_RED_API_KEY and IMPORT_API_KEY are identical"
  else
    fail "API_KEY, NODE_RED_API_KEY and IMPORT_API_KEY differ — the gateway will reject its own callers"
  fi
  if [ -n "$flow_key" ] && [ "${#flow_key}" -lt 32 ]; then
    fail "the gateway key is only ${#flow_key} characters — generate one with 'openssl rand -hex 32'"
  elif [ -n "$flow_key" ]; then
    pass "the gateway key is ${#flow_key} characters"
  fi

  bold "Services must be in production mode"
  check_mode() {
    local repo="$1" name="$2" expected="$3"
    local file="${ENV_FILES[$repo]:-}"
    [ -n "$file" ] || return 0
    local value; value="$(read_env_var "$file" "$name")"
    if [ "$value" = "$expected" ]; then
      pass "${repo}: ${name}=${expected}"
    else
      fail "${repo}: ${name} is '${value:-unset}', expected '${expected}' — the startup secret guard only runs in production mode"
    fi
  }
  check_mode compliance_flow   NODE_ENV           production
  check_mode compliance_web    AUTH_NODE_ENV      production
  check_mode compliance_import APP_ENV            production
  check_mode compliance_web    AUTH_COOKIE_SECURE true
fi

# ---------------------------------------------------------------------------
echo
bold "Result"
# ---------------------------------------------------------------------------
if [ "$PROFILE" = "demo" ]; then
  echo
  yellow "This is a DEMO configuration. The credentials above are published in"
  yellow "these repositories — the gateway API key, the Alfresco database"
  yellow "password, the Solr shared secret and the demo identities are all"
  yellow "known to anyone who has cloned any component repo."
  yellow ""
  yellow "Do not expose this stack to anyone you do not trust. Before a real"
  yellow "deployment, rotate every one of them and re-run:"
  yellow "    $0 --profile production"
  echo
  if [ "$FAILURES" -gt 0 ]; then
    red "${FAILURES} failure(s) — even the demo profile is misconfigured."
    exit 1
  fi
  green "Demo profile OK (${WARNINGS} expected warning(s))."
  exit 0
fi

if [ "$FAILURES" -gt 0 ]; then
  red "${FAILURES} failure(s). This configuration must not be deployed."
  exit 1
fi

green "Production profile OK."
echo
yellow "Two things this script cannot check, because they are not in a .env:"
yellow "  1. compliance_checklist stores its own copy of the gateway key,"
yellow "     entered in the app. It must match the value checked above."
yellow "  2. The demo identities (demo.inspector1, closure.reviewer, ci_admin)"
yellow "     live in Alfresco, not in a file. Remove them with"
yellow "     compliance_cmis/scripts/seed-demo-identities.sh --remove"
exit 0
