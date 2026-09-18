#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Computes the release tag for this repository and refuses to produce one when
# the release has not been prepared.
#
# Every repository in this platform carries a byte-identical copy of this file.
# If you change it, change all six (see CONTRIBUTING.md, "Versioning and
# releases").
#
# Usage:
#   scripts/release-tag.sh                 # print the tag, write nothing
#   scripts/release-tag.sh --env-file F    # also write RELEASE_TAG=<tag> to F
#                                          # (this is how CI consumes it)
#
# A release is tagged with the date of its CHANGELOG section (CalVer):
# YYYY-MM-DD, or YYYY-MM-DD.N for a second release on the same day. All of the
# following must hold, otherwise this script exits non-zero:
#
#   1. CHANGELOG.md has a dated release section, i.e. a "## [YYYY-MM-DD]"
#      heading, as its newest release section - directly under
#      "## [Unreleased]" when that heading is present. Older sections in other
#      formats (for example "## [0.5.0] - 2026-09-06") are history and ignored.
#   2. CHANGELOG.md changed between the previous release tag and HEAD, so a
#      release always ships an entry.
#   3. The computed tag is newer than the previous release tag and does not
#      exist yet.
#
# The checks that compare against a previous release need its tag to be
# present locally; a shallow clone without tags only warns.

set -eu

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
ENV_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/release-tag.sh [--env-file PATH]

Prints the CalVer release tag derived from CHANGELOG.md, after checking that
the release is properly prepared. With --env-file, also writes
"RELEASE_TAG=<tag>" to PATH (append creates the file if needed).
USAGE
}

fail() {
  printf 'release-tag: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || fail "--env-file needs a path"
      ENV_FILE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -f "$CHANGELOG" ] || fail "CHANGELOG.md is missing; every release needs one"

# Resolve the newest release section: the first "## " heading, skipping a
# leading "[Unreleased]" heading when there is one.
first_heading=$(grep -m1 '^## ' "$CHANGELOG" || true)
[ -n "$first_heading" ] || fail "CHANGELOG.md has no '## ' section yet"

case "$first_heading" in
  *'[Unreleased]'*)
    release_heading=$(grep -m2 '^## ' "$CHANGELOG" | sed -n 2p)
    ;;
  *)
    release_heading=$first_heading
    ;;
esac

tag=$(printf '%s\n' "$release_heading" |
  sed -nE 's/^##[[:space:]]+\[([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9](\.[0-9]+)?)\].*$/\1/p')

today=$(date -u +%Y-%m-%d)
[ -n "$tag" ] || fail "no dated release section in CHANGELOG.md: add '## [$today]' directly under '## [Unreleased]' before releasing (newest release heading: ${release_heading:-none})"

tag_date=${tag%%.*}

# Previous release tag, if any. -v:refname orders YYYY-MM-DD.N correctly.
previous_tag=$(git tag --sort=-v:refname 2>/dev/null |
  grep -E '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' |
  head -n1 || true)

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
  next_suffix=2
  if [ -n "$previous_tag" ] && [ "${previous_tag%%.*}" = "$tag_date" ]; then
    previous_suffix=${previous_tag#"$tag_date"}
    previous_suffix=${previous_suffix#.}
    [ -n "$previous_suffix" ] || previous_suffix=1
    next_suffix=$((previous_suffix + 1))
  fi
  fail "tag $tag already exists: if this is a second release on the same day, add '## [$tag_date.$next_suffix]' to CHANGELOG.md"
fi

if [ -n "$previous_tag" ]; then
  tag_number=$(printf '%s' "$tag_date" | tr -d '-')
  previous_number=$(printf '%s' "${previous_tag%%.*}" | tr -d '-')

  [ "$tag_number" -ge "$previous_number" ] ||
    fail "release $tag is older than the previous release $previous_tag; a release must not go backwards"

  if [ "$tag_number" -eq "$previous_number" ]; then
    previous_suffix=${previous_tag#"$tag_date"}
    previous_suffix=${previous_suffix#.}
    [ -n "$previous_suffix" ] || previous_suffix=1
    tag_suffix=${tag#"$tag_date"}
    tag_suffix=${tag_suffix#.}
    [ -n "$tag_suffix" ] || tag_suffix=1
    [ "$tag_suffix" -gt "$previous_suffix" ] ||
      fail "release $tag is not newer than $previous_tag; use $tag_date.$((previous_suffix + 1))"
  fi

  if git diff --quiet "$previous_tag" HEAD -- CHANGELOG.md; then
    fail "CHANGELOG.md is unchanged since $previous_tag: add the release section before releasing"
  fi
elif [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  echo "release-tag: warning: shallow clone without release tags; previous-release checks skipped" >&2
fi

if [ -n "$ENV_FILE" ]; then
  printf 'RELEASE_TAG=%s\n' "$tag" >>"$ENV_FILE"
fi

echo "release-tag: $tag (previous: ${previous_tag:-none})"
