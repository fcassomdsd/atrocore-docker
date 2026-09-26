#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Self-test for scripts/preflight-secrets.sh. Builds throwaway workspaces in a
# temporary directory, so it needs nothing from this checkout and no network,
# no Docker and no running stack.
#
#   bash scripts/preflight-secrets.test.sh
#
# The point of these cases is that the gate has to be able to PASS. A check
# that only ever fails gets bypassed, and a bypassed gate is worse than none,
# because it still reads as protection in the pipeline.

set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFLIGHT="$SCRIPT_DIR/preflight-secrets.sh"
WORK_DIR=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

check() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ok    %s\n' "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL  %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

check_output() {
  local description="$1" needle="$2" output="$3"
  if printf '%s' "$output" | grep -qF -- "$needle"; then
    printf '  ok    %s\n' "$description"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL  %s (output did not mention "%s")\n' "$description" "$needle"
    FAILED=$((FAILED + 1))
  fi
}

# A workspace whose every credential is real. $1 is the workspace directory.
make_production_workspace() {
  local ws="$1" key="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  mkdir -p "$ws"/{atrocore-docker,compliance_cmis,compliance_flow,compliance_import,compliance_web}
  cat > "$ws/compliance_flow/.env" <<EOF
NODE_ENV=production
API_KEY=$key
ALFRESCO_USERNAME=svc-alfresco
ALFRESCO_PASSWORD=r3al-alfresco-password
ATROCORE_USERNAME=svc-atrocore
ATROCORE_PASSWORD=r3al-atrocore-password
NODE_RED_CREDENTIAL_SECRET=r3al-credential-secret
ADMIN_USERNAME=opsadmin
ADMIN_PASSWORD_HASH=\$2a\$08\$notarealhashbutnotaplaceholder
EOF
  cat > "$ws/compliance_web/.env" <<EOF
AUTH_NODE_ENV=production
AUTH_COOKIE_SECURE=true
AUTH_TICKET_ENCRYPTION_KEY=r3al-ticket-encryption-key
POSTGRES_PASSWORD=r3al-web-db-password
NODE_RED_API_KEY=$key
EOF
  cat > "$ws/compliance_import/.env" <<EOF
APP_ENV=production
IMPORT_API_KEY=$key
EOF
  cat > "$ws/compliance_cmis/.env" <<EOF
DB_PASSWORD=r3al-alfresco-db-password
SOLR_SECRET=r3al-solr-shared-secret
METADATA_KEYSTORE_PASSWORD=r3al-keystore-password
METADATA_KEYSTORE_METADATA_PASSWORD=r3al-keystore-metadata-password
EOF
  cat > "$ws/atrocore-docker/.env" <<EOF
POSTGRES_PASSWORD=r3al-atrocore-root-password
POSTGRES_PIM_USER=atrocore
POSTGRES_PIM_PASSWORD=r3al-atrocore-pim-password
EOF
}

# A workspace configured the way the demo ships.
make_demo_workspace() {
  local ws="$1"
  mkdir -p "$ws"/{atrocore-docker,compliance_cmis,compliance_flow,compliance_import,compliance_web}
  cat > "$ws/compliance_flow/.env" <<'EOF'
NODE_ENV=development
API_KEY=demo-only-CHANGE-BEFORE-ANY-PUBLIC-DEPLOYMENT
ALFRESCO_USERNAME=admin
ALFRESCO_PASSWORD=admin
ATROCORE_USERNAME=admin
ATROCORE_PASSWORD=admin
NODE_RED_CREDENTIAL_SECRET=a-secret-key
ADMIN_USERNAME=admin
ADMIN_PASSWORD_HASH=replace-with-a-bcrypt-hash
EOF
  cat > "$ws/compliance_web/.env" <<'EOF'
AUTH_NODE_ENV=development
AUTH_COOKIE_SECURE=false
AUTH_TICKET_ENCRYPTION_KEY=change-me-for-non-dev
POSTGRES_PASSWORD=change-me
NODE_RED_API_KEY=demo-only-CHANGE-BEFORE-ANY-PUBLIC-DEPLOYMENT
EOF
  cat > "$ws/compliance_import/.env" <<'EOF'
IMPORT_API_KEY=demo-only-CHANGE-BEFORE-ANY-PUBLIC-DEPLOYMENT
EOF
  cat > "$ws/compliance_cmis/.env" <<'EOF'
DB_PASSWORD=alfresco
SOLR_SECRET=secret
METADATA_KEYSTORE_PASSWORD=mp6yc0UD9e
METADATA_KEYSTORE_METADATA_PASSWORD=oKIWzVdEdA
EOF
  cat > "$ws/atrocore-docker/.env" <<'EOF'
POSTGRES_PASSWORD=postgres-dev
POSTGRES_PIM_USER=atrocore
POSTGRES_PIM_PASSWORD=atrocore-dev
EOF
}

run() { "$PREFLIGHT" --workspace "$1" "${@:2}" 2>&1; }

echo "preflight-secrets self-test"
echo

# --- The gate must pass a genuinely production-ready workspace --------------
PROD="$WORK_DIR/prod"
make_production_workspace "$PROD"
OUT=$(run "$PROD" --profile production); RC=$?
check "a fully configured production workspace passes" 0 "$RC"
check_output "  ...and says so" "Production profile OK" "$OUT"

# --- The demo must keep working, unchanged ----------------------------------
DEMO="$WORK_DIR/demo"
make_demo_workspace "$DEMO"
OUT=$(run "$DEMO"); RC=$?
check "the demo workspace passes the demo profile" 0 "$RC"
check_output "  ...while naming the published values" "published demo value" "$OUT"
check_output "  ...and warning not to deploy it" "DEMO configuration" "$OUT"

# --- ...and must be refused as production -----------------------------------
OUT=$(run "$DEMO" --profile production); RC=$?
check "the demo workspace is refused by the production profile" 1 "$RC"
check_output "  ...naming the published database password" "DB_PASSWORD" "$OUT"
check_output "  ...and the development-mode services" "expected 'production'" "$OUT"

# --- Individual production failures -----------------------------------------
MISMATCH="$WORK_DIR/mismatch"
make_production_workspace "$MISMATCH"
sed -i "s/^IMPORT_API_KEY=.*/IMPORT_API_KEY=0000000000000000000000000000000000000000000000000000000000000000/" \
  "$MISMATCH/compliance_import/.env"
OUT=$(run "$MISMATCH" --profile production); RC=$?
check "mismatched gateway keys fail" 1 "$RC"
check_output "  ...explaining the consequence" "reject its own callers" "$OUT"

SHORTKEY="$WORK_DIR/shortkey"
make_production_workspace "$SHORTKEY"
for f in compliance_flow/.env compliance_web/.env compliance_import/.env; do
  sed -i -E "s/^(API_KEY|NODE_RED_API_KEY|IMPORT_API_KEY)=.*/\1=abc123/" "$SHORTKEY/$f"
done
OUT=$(run "$SHORTKEY" --profile production); RC=$?
check "a short gateway key fails" 1 "$RC"
check_output "  ...suggesting how to generate one" "openssl rand -hex 32" "$OUT"

MISSING="$WORK_DIR/missing"
make_production_workspace "$MISSING"
sed -i "/^AUTH_TICKET_ENCRYPTION_KEY=/d" "$MISSING/compliance_web/.env"
OUT=$(run "$MISSING" --profile production); RC=$?
check "a missing required secret fails" 1 "$RC"
check_output "  ...naming it" "AUTH_TICKET_ENCRYPTION_KEY is unset" "$OUT"

DEVMODE="$WORK_DIR/devmode"
make_production_workspace "$DEVMODE"
sed -i "s/^NODE_ENV=production/NODE_ENV=development/" "$DEVMODE/compliance_flow/.env"
OUT=$(run "$DEVMODE" --profile production); RC=$?
check "a service left in development mode fails" 1 "$RC"

INSECURE_COOKIE="$WORK_DIR/cookie"
make_production_workspace "$INSECURE_COOKIE"
sed -i "s/^AUTH_COOKIE_SECURE=true/AUTH_COOKIE_SECURE=false/" "$INSECURE_COOKIE/compliance_web/.env"
OUT=$(run "$INSECURE_COOKIE" --profile production); RC=$?
check "insecure session cookies fail" 1 "$RC"

# --- A default username is a warning, not a deployment blocker --------------
# Failing over ADMIN_USERNAME=admin would train people to pass --profile demo
# to get past the check, which defeats the whole gate.
USERNAME="$WORK_DIR/username"
make_production_workspace "$USERNAME"
sed -i "s/^ADMIN_USERNAME=.*/ADMIN_USERNAME=admin/" "$USERNAME/compliance_flow/.env"
OUT=$(run "$USERNAME" --profile production); RC=$?
check "a default username warns but does not block" 0 "$RC"
check_output "  ...and is still reported" "not a credential" "$OUT"

# --- A missing .env is fatal for production, tolerable for the demo ---------
NOENV="$WORK_DIR/noenv"
make_production_workspace "$NOENV"
rm "$NOENV/compliance_cmis/.env"
OUT=$(run "$NOENV" --profile production); RC=$?
check "a missing .env fails the production profile" 1 "$RC"

echo
if [ "$FAILED" -gt 0 ]; then
  printf '%s passed, %s FAILED\n' "$PASSED" "$FAILED"
  exit 1
fi
printf 'all %s checks passed\n' "$PASSED"
