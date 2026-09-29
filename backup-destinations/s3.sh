#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Backup destination: S3, or anything speaking its API.
#
# Tested against MinIO, which is also how an authority can run this entirely
# on its own hardware. The same driver reaches AWS, Ceph/RadosGW, Wasabi and
# most national cloud offerings; only the endpoint changes.
#
#   BACKUP_S3_BUCKET     required. Bucket name.
#   BACKUP_S3_PREFIX     optional. Key prefix, default "backups".
#   BACKUP_S3_ENDPOINT   optional. For anything that is not AWS itself,
#                        e.g. https://minio.authority.example
#   BACKUP_S3_REGION     optional, default us-east-1 (what most
#                        S3-compatible servers expect when they ignore it).
#   BACKUP_S3_PRUNES_ITSELF  optional. Set to 1 when the bucket carries a
#                        lifecycle rule that expires old sets. The driver
#                        then reports prune=self and the dispatcher does not
#                        prune -- see the note below.
#
# Credentials come from the environment the way the AWS CLI already expects
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, or an instance role, or a
# profile). That is deliberate: this platform's rule is that a credential
# never lives in a tracked file, and the CLI's own resolution already
# supports file-based and role-based sources.
#
# ON prune=self
# -------------
# A bucket lifecycle rule and a client-side prune are two policies for one
# question, and they will eventually disagree -- usually by the client
# deleting a set the rule was configured to retain, or by both deciding the
# other is handling it. Declaring which one is in charge is the point of the
# capability.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/set-age.sh"

VERB="${1:-}"; shift || true
BUCKET="${BACKUP_S3_BUCKET:-}"
PREFIX="${BACKUP_S3_PREFIX:-backups}"

# Checked per operation rather than at load, so `capabilities` still answers
# on a machine without the CLI. Discovery should work everywhere; only doing
# something needs the tool.
need_aws() {
  command -v aws >/dev/null 2>&1 || { echo "s3: the aws CLI is not installed" >&2; exit 2; }
}

need_bucket() {
  need_aws
  [ -n "${BUCKET}" ] || { echo "s3: BACKUP_S3_BUCKET is not set" >&2; exit 2; }
}

s3() {
  local args=(--region "${BACKUP_S3_REGION:-us-east-1}")
  [ -n "${BACKUP_S3_ENDPOINT:-}" ] && args+=(--endpoint-url "${BACKUP_S3_ENDPOINT}")
  aws "${args[@]}" "$@"
}

base() { printf 's3://%s/%s' "${BUCKET}" "${PREFIX}"; }

case "${VERB}" in
  capabilities)
    echo "name=s3"
    echo "fetch=yes"
    if [ "${BACKUP_S3_PRUNES_ITSELF:-0}" = "1" ]; then echo "prune=self"; else echo "prune=yes"; fi
    ;;

  push)
    need_bucket
    SRC="${1:?push needs <set-dir>}"; ID="${2:?push needs <set-id>}"
    # Everything but MANIFEST, then MANIFEST. A multi-file sync can fail
    # part way through, and a set whose MANIFEST is present is treated as
    # complete -- so the manifest is the commit point, exactly as the
    # release update feed treats latest.yml.
    s3 s3 sync "${SRC}/" "$(base)/${ID}/" --exclude MANIFEST --only-show-errors
    if [ -f "${SRC}/MANIFEST" ]; then
      s3 s3 cp "${SRC}/MANIFEST" "$(base)/${ID}/MANIFEST" --only-show-errors
    fi
    ;;

  pull)
    need_bucket
    ID="${1:?pull needs <set-id>}"; DEST="${2:?pull needs <dest-dir>}"
    mkdir -p "${DEST}"
    s3 s3 sync "$(base)/${ID}/" "${DEST}/" --only-show-errors
    # sync is silent about a prefix that does not exist, which would leave an
    # empty directory looking like a successful fetch.
    [ -n "$(ls -A "${DEST}" 2>/dev/null)" ] || { echo "s3: no such set: ${ID}" >&2; exit 1; }
    ;;

  list)
    need_bucket
    # Common prefixes only. `| sort` because ordering is not guaranteed.
    s3 s3 ls "$(base)/" 2>/dev/null | awk '/PRE/ {gsub(/\//,"",$2); print $2}' | sort
    ;;

  prune)
    need_bucket
    KEEP="${1:?prune needs <keep-days>}"
    if [ "${BACKUP_S3_PRUNES_ITSELF:-0}" = "1" ]; then
      echo "0"
      exit 0
    fi
    pruned=0
    while IFS= read -r id; do
      [ -n "${id}" ] || continue
      if set_is_older_than "${id}" "${KEEP}"; then
        s3 s3 rm "$(base)/${id}/" --recursive --only-show-errors && pruned=$((pruned + 1))
      fi
    done < <(s3 s3 ls "$(base)/" 2>/dev/null | awk '/PRE/ {gsub(/\//,"",$2); print $2}' | sort)
    echo "${pruned}"
    ;;

  *) echo "s3: unknown verb '${VERB}'" >&2; exit 2 ;;
esac
