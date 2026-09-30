#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Solr's index as a recovery concern. Sourced by measure-rto.sh and
# restore-verify-ci.sh so the two cannot disagree about what "search is back"
# means.
#
# WHY A RESTORE DRILL HAS TO CARE
# -------------------------------
# Solr is derived state and is deliberately not backed up. On a blank host it
# does not exist, so a restore that puts every byte back still leaves the
# reads that depend on search broken until Alfresco has reindexed -- and
# those reads are not incidental: the checklist endpoint, open findings, and
# four report Web Scripts.
#
# A drill that restores while an already-correct index happens to be sitting
# there is not drilling the case that actually occurs. It also has nowhere to
# put an assertion: it can only tolerate a partially failing smoke matrix,
# because it cannot tell an index that is still catching up from one that
# never will. Destroying the index first removes the ambiguity and turns that
# tolerance into a wait followed by a hard check.
#
# CONFIGURE WITH
#   SOLR_ENDPOINT   host:port of the Solr admin API (default localhost:8083)

SOLR_ENDPOINT="${SOLR_ENDPOINT:-localhost:8083}"

# solr_secret <compliance_cmis dir> -- the shared secret both Alfresco and
# Solr are started with. Parsed, never sourced.
solr_secret() {
  local v=""
  [ -f "$1/.env" ] && v="$(sed -n 's/^[[:space:]]*SOLR_SECRET=//p' "$1/.env" | tail -n1 \
      | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//')"
  printf '%s' "${v:-secret}"
}

# solr_field <secret> <field name from the SUMMARY report>
solr_field() {
  curl -s -m 15 -H "X-Alfresco-Search-Secret: $1" \
    "http://${SOLR_ENDPOINT}/solr/admin/cores?action=SUMMARY&wt=json" 2>/dev/null \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin)['Summary']['alfresco']
except Exception: sys.exit(1)
v=d.get(sys.argv[1])
print('' if v is None else v)
" "$2" 2>/dev/null
}

solr_index_nodes() { solr_field "$1" 'Alfresco Nodes in Index'; }

# solr_destroy_index <compliance_cmis dir>
#
# The index lives in the container's anonymous volumes, not in the
# bind-mounted data/ tree, so `docker compose rm -sfv` is how it is spelled.
# The volume IDs are read first and asserted gone afterwards: if the removal
# silently fails, everything downstream measures an index that was never
# destroyed, and reports a reindex that never happened.
solr_destroy_index() {
  local dir="$1" vols v survivors=0
  vols="$(docker inspect compliance_cmis-solr6-1 --format '{{range .Mounts}}{{.Name}} {{end}}' 2>/dev/null)"
  [ -n "${vols}" ] || { echo "could not read Solr's volumes" >&2; return 1; }
  ( cd "${dir}" && docker compose rm -sfv solr6 >/dev/null 2>&1 ) \
    || { echo "could not remove the Solr container" >&2; return 1; }
  for v in ${vols}; do
    docker volume inspect "${v}" >/dev/null 2>&1 && survivors=$((survivors + 1))
  done
  [ "${survivors}" -eq 0 ] || {
    echo "${survivors} Solr volume(s) survived removal — the index was not destroyed" >&2; return 1; }
  printf '%s' "$(printf '%s' "${vols}" | wc -w)"
}

# solr_wait_indexed <secret> <target nodes> <max seconds> [progress every N polls]
#
# Waits until the index holds at least <target> nodes AND reports nothing
# outstanding, twice in a row. Both halves matter:
#
#   - "zero transactions remaining" alone is what an index that has not begun
#     tracking reports, so waiting on it returns almost immediately against an
#     empty index;
#   - the tracker also reports zero between batches, hence twice in a row.
#
# Sets SOLR_LOW_WATER to the smallest index size seen, so a caller can prove
# the index really was rebuilt rather than never emptied.
solr_wait_indexed() {
  local secret="$1" target="$2" max="$3" every="${4:-15}"
  local caught=0 i n rem polls
  polls=$(( max / 2 )); [ "${polls}" -lt 1 ] && polls=1
  SOLR_LOW_WATER=-1
  for i in $(seq 1 "${polls}"); do
    n="$(solr_index_nodes "${secret}")"
    rem="$(solr_field "${secret}" 'Approx transactions remaining')"
    case "${n}" in ''|*[!0-9]*) n=-1 ;; esac
    if [ "${n}" -ge 0 ] && { [ "${SOLR_LOW_WATER}" -lt 0 ] || [ "${n}" -lt "${SOLR_LOW_WATER}" ]; }; then
      SOLR_LOW_WATER="${n}"
    fi
    if [ "${n}" -ge "${target}" ] && [ "${rem}" = "0" ]; then
      caught=$((caught + 1))
      [ "${caught}" -ge 2 ] && return 0
    else
      caught=0
    fi
    [ $(( i % every )) -eq 0 ] && printf '    ..   indexed %s/%s nodes, %s transaction(s) remaining\n' \
      "${n}" "${target}" "${rem:-?}"
    sleep 2
  done
  return 1
}
