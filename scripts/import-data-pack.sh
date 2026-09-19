#!/usr/bin/env bash
#
# Import the authority data packs (data-packs/) through AtroCore's own import module.
#
# The implementation is scripts/import-data-pack.py — the packs, the column mappings and the
# REST calls are all JSON-shaped, which is clearer in Python than in shell. This wrapper exists
# so the command reads like every other script in this directory (and so `make import-data-packs`
# has one stable name to call).
#
#   scripts/import-data-pack.sh --list
#   scripts/import-data-pack.sh --all
#   scripts/import-data-pack.sh location inspector
#   scripts/import-data-pack.sh location --file my-locations.csv
#
# Credentials come from ../compliance_flow/.env or this repo's .env (ATROCORE_USERNAME /
# ATROCORE_PASSWORD); the API host from ATROCORE_API_BASE, then DEMO_HOST (default localhost).
# See data-packs/README.md for what each pack maps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to import the data packs." >&2
  exit 1
fi

exec python3 "${SCRIPT_DIR}/import-data-pack.py" "$@"
