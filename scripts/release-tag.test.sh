#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Fernando A. Casso Rodriguez
#
# Self-test for scripts/release-tag.sh. Builds throwaway repositories in a
# temporary directory, so it needs git but touches nothing in this checkout.
# Run it directly (it needs no arguments and no network):
#
#   sh scripts/release-tag.test.sh
#
# Every repository in this platform carries a byte-identical copy of both this
# file and release-tag.sh (see CONTRIBUTING.md, "Versioning and releases").

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RELEASE_TAG="$SCRIPT_DIR/release-tag.sh"
WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t release-tag)
PASSED=0

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

git_quiet() {
  git -c user.email=ci@example.invalid -c user.name="Release Self-Test" "$@"
}

new_repo() {
  repo="$WORK_DIR/$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git symbolic-ref HEAD refs/heads/main
  )
  printf '%s\n' "$repo"
}

write_changelog() {
  repo=$1
  shift
  {
    printf '# Changelog\n\nAll notable changes are documented in this file.\n'
    for section in "$@"; do
      printf '\n## [%s]\n\n### Changed\n\n- Something worth releasing.\n' "$section"
    done
  } >"$repo/CHANGELOG.md"
}

commit_all() {
  repo=$1
  message=$2
  (
    cd "$repo"
    git add -A
    git_quiet commit -q -m "$message"
  )
}

run_release_tag() {
  repo=$1
  shift
  (cd "$repo" && sh "$RELEASE_TAG" "$@")
}

ok() {
  PASSED=$((PASSED + 1))
  printf 'ok %2d - %s\n' "$PASSED" "$1"
}

fails() {
  description=$1
  shift
  if output=$("$@" 2>&1); then
    printf 'FAIL - %s: expected a non-zero exit, got success\n%s\n' "$description" "$output" >&2
    exit 1
  fi
  ok "$description"
}

succeeds() {
  description=$1
  shift
  if ! output=$("$@" 2>&1); then
    printf 'FAIL - %s: expected success, got failure\n%s\n' "$description" "$output" >&2
    exit 1
  fi
  ok "$description"
}

equals() {
  description=$1
  expected=$2
  actual=$3
  if [ "$expected" != "$actual" ]; then
    printf 'FAIL - %s: expected "%s", got "%s"\n' "$description" "$expected" "$actual" >&2
    exit 1
  fi
  ok "$description"
}

tag_of() {
  run_release_tag "$1" | sed -n 's/^release-tag: \([^ ]*\).*$/\1/p'
}

# 1. No CHANGELOG.md at all.
repo=$(new_repo no-changelog)
printf 'nothing to see\n' >"$repo/README.md"
commit_all "$repo" "initial"
fails "rejects a repository without CHANGELOG.md" run_release_tag "$repo"

# 2. Only an Unreleased section: nothing prepared for release.
repo=$(new_repo unreleased-only)
printf '# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- Work in progress.\n' >"$repo/CHANGELOG.md"
commit_all "$repo" "unreleased only"
fails "rejects an Unreleased-only changelog" run_release_tag "$repo"

# 3. A dated section directly under Unreleased, no tags yet.
repo=$(new_repo first-release)
write_changelog "$repo" "Unreleased" "2026-09-14"
commit_all "$repo" "prepare 2026-09-14"
equals "derives the tag from the first dated section" "2026-09-14" "$(tag_of "$repo")"

# 4. The newest dated section wins, not the oldest.
repo=$(new_repo newest-wins)
write_changelog "$repo" "Unreleased" "2026-09-15" "2026-09-14"
commit_all "$repo" "two dated sections"
equals "uses the newest dated section" "2026-09-15" "$(tag_of "$repo")"

# 5. The tag already exists: a second release needs its own section.
repo=$(new_repo collision)
write_changelog "$repo" "Unreleased" "2026-09-14"
commit_all "$repo" "prepare 2026-09-14"
(cd "$repo" && git tag 2026-09-14)
fails "rejects a tag that already exists" run_release_tag "$repo"

# 6. A same-day second release is numbered.
repo=$(new_repo same-day-second)
write_changelog "$repo" "Unreleased" "2026-09-14" "2026-09-13"
commit_all "$repo" "prepare 2026-09-14"
(cd "$repo" && git tag 2026-09-14)
write_changelog "$repo" "Unreleased" "2026-09-14.2" "2026-09-14"
commit_all "$repo" "prepare 2026-09-14.2"
equals "accepts a numbered second release on the same day" "2026-09-14.2" "$(tag_of "$repo")"

# 7. Going backwards is rejected.
repo=$(new_repo backwards)
write_changelog "$repo" "Unreleased" "2026-09-10"
commit_all "$repo" "prepare 2026-09-10"
(cd "$repo" && git tag 2026-09-14)
fails "rejects a release older than the previous tag" run_release_tag "$repo"

# 8. The release section must be part of the release: a changelog untouched
#    since the previous tag cannot be released under a new tag.
repo=$(new_repo unchanged-changelog)
write_changelog "$repo" "Unreleased" "2026-09-15"
commit_all "$repo" "prepare 2026-09-15"
(cd "$repo" && git tag 2026-09-14)
printf 'code\n' >"$repo/service.sh"
commit_all "$repo" "code only"
fails "rejects a changelog unchanged since the previous release" run_release_tag "$repo"

# 9. --env-file writes the variable CI consumes.
repo=$(new_repo env-file)
write_changelog "$repo" "Unreleased" "2026-09-16"
commit_all "$repo" "prepare 2026-09-16"
run_release_tag "$repo" --env-file "$repo/release.env" >/dev/null
equals "--env-file writes RELEASE_TAG" "RELEASE_TAG=2026-09-16" "$(cat "$repo/release.env")"

printf '\nrelease-tag self-test: %d checks passed\n' "$PASSED"
