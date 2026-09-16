#!/usr/bin/env python3
"""Export the running instance's AtroCore metadata, or check it for drift.

`install-metadata.sh` copies `metadata/` **into** the instance. This does the
opposite, and it exists because of how the operational model went missing: someone
edits an entity through the AtroCore admin UI, the change lives only in the
gitignored `web-data/` tree, and the next clean build silently loses it. For months
that is how 19 of the 32 entity definitions stayed untracked.

Usage:
    scripts/export-instance-metadata.py --check          # report drift, change nothing
    scripts/export-instance-metadata.py                  # copy runtime -> metadata/ (tracked entities)
    scripts/export-instance-metadata.py --include-new    # also add entities the repo does not track

`--check` exits non-zero when anything differs, so it can gate a merge or a release.

The tracked set is the contract: the first two modes only touch entities that are
already in the repository. An entity that exists **only** at runtime is reported as
untracked — adding it is deliberate, because it must also be listed in
`EXPECTED_ENTITIES` in `scripts/validate-metadata.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METADATA = ROOT / "metadata"

# (label, repo directory, runtime directory, tree-of-directories?)
TREES = (
    ("entityDefs", METADATA / "entityDefs", "metadata/entityDefs", False),
    ("clientDefs", METADATA / "clientDefs", "metadata/clientDefs", False),
    ("scopes", METADATA / "scopes", "metadata/scopes", False),
    ("layouts", METADATA / "layouts", "layouts", True),
)


def read_env_domain() -> str:
    env_file = ROOT / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("PRODUCTION_DOMAIN="):
                return line.split("=", 1)[1].strip().strip("'\"") or "localhost"
    return os.environ.get("PRODUCTION_DOMAIN", "localhost")


def runtime_root() -> Path:
    root = ROOT / "web-data" / read_env_domain() / "data"
    if not root.is_dir():
        sys.exit(
            f"Error: {root} does not exist.\n"
            "Start the stack (docker compose up -d --build), bootstrap the application\n"
            "(./scripts/bootstrap-web-data.sh) and install the metadata first."
        )
    return root


def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def entries(directory: Path, is_tree: bool) -> set[str]:
    if not directory.is_dir():
        return set()
    if is_tree:
        return {p.name for p in directory.iterdir() if p.is_dir()}
    return {p.stem for p in directory.glob("*.json")}


def compare_tree(label: str, repo_dir: Path, run_dir: Path, is_tree: bool) -> tuple[list[str], list[str], list[str]]:
    """Return (differing, missing_at_runtime, runtime_only) entity names."""
    differing: list[str] = []
    missing: list[str] = []
    runtime_only: list[str] = []

    repo_entities = entries(repo_dir, is_tree)
    run_entities = entries(run_dir, is_tree)

    for entity in sorted(repo_entities):
        if entity not in run_entities:
            missing.append(entity)
            continue
        if is_tree:
            repo_files = {p.name: load(p) for p in (repo_dir / entity).glob("*.json")}
            run_files = {p.name: load(p) for p in (run_dir / entity).glob("*.json")}
            if repo_files != run_files:
                differing.append(entity)
        else:
            if load(repo_dir / f"{entity}.json") != load(run_dir / f"{entity}.json"):
                differing.append(entity)

    runtime_only = sorted(run_entities - repo_entities)
    return differing, missing, runtime_only


def copy_tree(label: str, repo_dir: Path, run_dir: Path, is_tree: bool, include_names: set[str]) -> list[str]:
    """Copy runtime -> repo for entities that are already tracked, plus include_names."""
    copied: list[str] = []

    if is_tree:
        for entity in sorted(entries(run_dir, True)):
            target = repo_dir / entity
            if not (target.is_dir() or entity in include_names):
                continue  # runtime-only and not requested: leave it alone
            target.mkdir(parents=True, exist_ok=True)
            for path in sorted((run_dir / entity).glob("*.json")):
                shutil.copy2(path, target / path.name)
            copied.append(f"{label}/{entity}")
        return copied

    for entity in sorted(entries(run_dir, False)):
        source = run_dir / f"{entity}.json"
        if not source.is_file():
            continue
        if not ((repo_dir / source.name).exists() or entity in include_names):
            continue  # runtime-only and not requested: leave it alone
        repo_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, repo_dir / source.name)
        copied.append(f"{label}/{source.name}")
    return copied


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="report drift and exit non-zero; change nothing")
    parser.add_argument(
        "--include-new",
        action="store_true",
        help="also copy entities that exist only at runtime (remember EXPECTED_ENTITIES in validate-metadata.py)",
    )
    args = parser.parse_args()

    run_root = runtime_root()

    if args.check:
        problems: list[str] = []
        untracked: set[str] = set()
        for label, repo_dir, run_subdir, is_tree in TREES:
            differing, missing, runtime_only = compare_tree(
                label, repo_dir, run_root / run_subdir, is_tree
            )
            problems += [f"{label}/{name}: tracked and runtime definitions differ" for name in differing]
            problems += [f"{label}/{name}: tracked but absent at runtime" for name in missing]
            untracked |= set(runtime_only)

        if problems:
            print(f"DRIFT: {len(problems)} difference(s) between metadata/ and the running instance:", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
        if untracked:
            print(
                f"\n{len(untracked)} entity(ies) exist only at runtime: {', '.join(sorted(untracked))}",
                file=sys.stderr,
            )
            print("Export them deliberately if they belong to the model (see --include-new).", file=sys.stderr)
        if problems:
            return 1
        print("OK: metadata/ matches the running instance" + (f" ({len(untracked)} untracked)" if untracked else ""))
        return 0

    include_names: set[str] = set()
    if args.include_new:
        for _label, repo_dir, run_subdir, is_tree in TREES:
            include_names |= entries(run_root / run_subdir, is_tree) - entries(repo_dir, is_tree)

    copied: list[str] = []
    for label, repo_dir, run_subdir, is_tree in TREES:
        copied += copy_tree(label, repo_dir, run_root / run_subdir, is_tree, include_names)

    print(f"Exported {len(copied)} entry(ies) from {run_root} into metadata/:")
    for entry in copied:
        print(f"  {entry}")
    if include_names:
        print(
            "\nNew entities were included: add them to EXPECTED_ENTITIES in "
            "scripts/validate-metadata.py, then run it."
        )
    print("\nReview the diff, then: ./scripts/install-metadata.sh is NOT needed — the instance is the source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
