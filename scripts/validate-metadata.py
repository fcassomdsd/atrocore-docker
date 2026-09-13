#!/usr/bin/env python3
"""Validate the tracked AtroCore metadata overlay.

CI previously booted the stack and checked a table count, which said nothing
about the metadata itself. This script checks that:

  * every metadata/**/*.json file parses as JSON
  * every entity definition declares ``fields`` and ``links``
  * entity definition names are unique
  * every link target resolves to either a tracked entity definition or a
    known upstream/base entity

The last check is the one that matters most: the overlay routinely links to
entities that live in the AtroCore base or are still admin-UI-only, so a typo in
an entity name currently goes unnoticed until runtime.

Usage:
    python3 scripts/validate-metadata.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METADATA = ROOT / "metadata"
ENTITY_DEFS = METADATA / "entityDefs"

# Entities that live in the AtroCore base or remain admin-UI-only. Prefer
# tracking a definition under metadata/entityDefs over extending this list.
KNOWN_UPSTREAM_ENTITIES = {
    "DocumentoOACI",
    "Finding",
    "InspectedProvider",
    "InspectedService",
    "InspectedSpecialty",
    "InspectionSchedule",
    "Inspector",
    "Location",
    "LocationService",
    "Reglamento",
    "User",
}

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


# ---------------------------------------------------------------- parse all
parsed: dict[Path, object] = {}

if not METADATA.is_dir():
    fail("metadata/ directory is missing")
else:
    for path in sorted(METADATA.rglob("*.json")):
        try:
            parsed[path] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"{path.relative_to(ROOT)}: invalid JSON: {exc}")

# ------------------------------------------------------- entity definitions
tracked: set[str] = set()
entity_defs: dict[str, dict] = {}

if not ENTITY_DEFS.is_dir():
    fail("metadata/entityDefs/ is missing")
else:
    for path in sorted(ENTITY_DEFS.glob("*.json")):
        name = path.stem
        data = parsed.get(path)

        if data is None:
            continue  # already reported as invalid JSON

        if not isinstance(data, dict):
            fail(f"metadata/entityDefs/{path.name}: expected a JSON object")
            continue

        if name in tracked:
            fail(f"duplicate entity definition: {name}")

        tracked.add(name)
        entity_defs[name] = data

        for required in ("fields", "links"):
            if required not in data:
                fail(f"metadata/entityDefs/{path.name}: missing '{required}'")

# ------------------------------------------------------------- link targets
def check_target(entity: object, where: str) -> None:
    if not isinstance(entity, str) or not entity:
        fail(f"{where}: link is missing an 'entity' value")
        return
    if entity in tracked or entity in KNOWN_UPSTREAM_ENTITIES:
        return
    fail(
        f"{where}: link targets unknown entity '{entity}' "
        f"(not tracked in metadata/entityDefs and not in KNOWN_UPSTREAM_ENTITIES)"
    )


for name, data in entity_defs.items():
    links = data.get("links") or {}
    if not isinstance(links, dict):
        fail(f"metadata/entityDefs/{name}.json: 'links' must be an object")
    else:
        for link_name, definition in links.items():
            if not isinstance(definition, dict):
                fail(f"metadata/entityDefs/{name}.json: link '{link_name}' is not an object")
                continue
            check_target(definition.get("entity"), f"metadata/entityDefs/{name}.json link '{link_name}'")

    fields = data.get("fields") or {}
    if isinstance(fields, dict):
        for field_name, definition in fields.items():
            if isinstance(definition, dict) and definition.get("type") == "link" and "entity" in definition:
                check_target(definition.get("entity"), f"metadata/entityDefs/{name}.json field '{field_name}'")

# ------------------------------------------------------------------ report
if errors:
    print(f"FAIL: {len(errors)} metadata problem(s):", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

rel = ", ".join(sorted(f"{name}.json" for name in entity_defs))
print(f"OK: {len(parsed)} metadata JSON files valid; {len(entity_defs)} entity definitions: {rel}")
