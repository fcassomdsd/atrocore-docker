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

# Entity definitions that must be tracked. Deliberately explicit: without it,
# deleting a file silently shrinks the model — which is precisely how the
# operational entities stayed untracked while a fresh clone built a schema without
# them. Adding an entity means adding it here too.
EXPECTED_ENTITIES = frozenset({
    "AcapiteOACI", "ActingInspector", "ActivityType", "AssignmentGroup",
    "ChecklistQuestion", "CorrectiveAction", "CorrectiveActionFollowUp",
    "CorrectiveActionPlan", "DocumentoOACI", "Finding", "FindingSeverity",
    "InspectedProvider", "InspectedService", "InspectedSpecialty", "Inspection",
    "InspectionCadence", "InspectionQuestion", "InspectionSchedule", "Inspector",
    "Location", "LocationService", "Normativa", "Person", "QuestionTopic",
    "Reglamento", "ServiceArea", "ServiceProvider", "SiteVisit", "Specialty",
    "Tag", "UsoapEvidenceExpectation", "UsoapProtocolQuestion",
})

# The only entities the model links to that live upstream in the AtroCore base.
# This list used to hold eleven entries, several of which were project entities that
# simply were not tracked — an escape hatch that would have let one of them vanish
# again without failing. Prefer tracking a definition over extending this.
KNOWN_UPSTREAM_ENTITIES = {"User"}

# The model is one-to-one: every entity has a client definition, a scope and a
# layout directory, and there are no orphans in any of the four trees.
CLIENT_DEFS = METADATA / "clientDefs"
SCOPES = METADATA / "scopes"
LAYOUTS = METADATA / "layouts"

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

# ----------------------------------------------- expected set and 1:1 coverage
missing_entities = sorted(EXPECTED_ENTITIES - tracked)
unexpected_entities = sorted(tracked - EXPECTED_ENTITIES)

if missing_entities:
    fail(
        f"metadata/entityDefs/ is missing {len(missing_entities)} expected definition(s): "
        f"{', '.join(missing_entities)}"
    )

if unexpected_entities:
    fail(
        f"metadata/entityDefs/ has {len(unexpected_entities)} definition(s) that "
        f"EXPECTED_ENTITIES does not list (add them deliberately): "
        f"{', '.join(unexpected_entities)}"
    )

for label, directory, is_directory_tree in (
    ("clientDefs", CLIENT_DEFS, False),
    ("scopes", SCOPES, False),
    ("layouts", LAYOUTS, True),
):
    if not directory.is_dir():
        fail(f"metadata/{label}/ is missing")
        continue

    if is_directory_tree:
        present = {p.name for p in directory.iterdir() if p.is_dir()}
    else:
        present = {p.stem for p in directory.glob("*.json")}

    for name in sorted(tracked - present):
        fail(f"metadata/{label}/: no entry for entity '{name}' (the model is one-to-one)")
    for name in sorted(present - tracked):
        fail(f"metadata/{label}/: '{name}' has no entity definition in metadata/entityDefs/")

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
