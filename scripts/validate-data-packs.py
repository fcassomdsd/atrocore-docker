#!/usr/bin/env python3
"""Validate the authority data packs (`data-packs/`) statically — no database or Docker needed.

The packs are the import-module route to the same records `sql/seed-starter-dataset.sql` seeds,
so the two must stay in lockstep: an adopter who imports the CSVs instead of running the seed
must land the identical rows. This script is the container-free half of that contract; the
`fresh-install` CI job is the other half (it applies the seed and then imports every pack, so a
pack whose links or required fields no longer fit the metadata fails there).

Checks:
  * `packs.json` shape: entity / code / title / non-empty columns, unique field and header names.
  * every pack has a CSV under `data-packs/` whose header row matches the pack's columns.
  * every mapped field exists in `metadata/entityDefs/<Entity>.json`, and every relationship
    column declares how to match the related record (`importBy`).
  * ids are namespaced `starter-` and unique across all packs.
  * the ids each pack defines are exactly the ids `seed-starter-dataset.sql` writes to that
    entity's table — so neither onboarding path can drift from the other.

Usage:
    scripts/validate-data-packs.py
"""

from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKS_FILE = ROOT / "data-packs" / "packs.json"
PACKS_DIR = ROOT / "data-packs"
ENTITY_DEFS = ROOT / "metadata" / "entityDefs"
STARTER_SQL = ROOT / "sql" / "seed-starter-dataset.sql"

# The seed also writes join rows (e.g. `starter-insp-01-ats` for Inspector↔Specialty) that no
# pack maps to a column of its own — the Inspector pack's `specialty` column creates them.
SEED_TABLES_WITHOUT_PACKS = {"inspector_specialty", "location_service_specialty"}

# `importBy` names an attribute on the *related* entity, so it has to exist there and be a
# storable, matchable type. These mirror Import\FieldConverters\Link::ALLOWED_TYPES.
ALLOWED_IMPORT_BY_TYPES = {"bool", "enum", "varchar", "float", "int", "text", "wysiwyg"}

RELATIONSHIP_TYPES = {"link", "linkMultiple", "hasMany", "belongsTo", "hasOne"}

# Espo/AtroCore provide these on every entity without declaring them in `entityDefs`.
IMPLICIT_FIELDS = {"id", "deleted", "createdAt", "modifiedAt", "createdBy", "modifiedBy"}


def snake_case(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def entity_definition(entity: str) -> dict:
    path = ENTITY_DEFS / f"{entity}.json"
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def check_import_by(
    label: str, entity: str, field: str, import_by: list[str], entity_links: dict
) -> list[str]:
    """`importBy` must name the id or a storable, matchable field on the *related* entity — that
    is exactly what the import module's Link converter accepts, so mirror it here rather than
    allow a fixed list of favourites."""
    link = entity_links.get(field) or {}
    foreign = link.get("entity")
    if not foreign:
        return [
            f"{label}: cannot resolve the related entity for '{field}' from "
            f"metadata/entityDefs/{entity}.json links"
        ]
    foreign_def = entity_definition(foreign)
    foreign_fields = foreign_def.get("fields") or {}
    if not foreign_fields:
        return [f"{label}: metadata/entityDefs/{foreign}.json (related to '{field}') is missing"]

    problems = []
    for value in import_by:
        if value == "id":
            continue
        spec = foreign_fields.get(value)
        if not spec:
            problems.append(
                f"{label}: '{field}' matches on '{value}', which is not a field of {foreign}"
            )
        elif spec.get("notStorable"):
            problems.append(f"{label}: '{field}' matches on '{value}', which is not storable in {foreign}")
        elif spec.get("type") not in ALLOWED_IMPORT_BY_TYPES:
            problems.append(
                f"{label}: '{field}' matches on '{value}' ({spec.get('type')}), which the import "
                f"module cannot match by — expected one of {sorted(ALLOWED_IMPORT_BY_TYPES)}"
            )
    return problems


def seed_rows_by_table(sql: str) -> dict[str, list[str]]:
    """Map each table the seed inserts into to the ids of the rows it inserts."""
    rows: dict[str, list[str]] = {}
    for chunk in sql.split("INSERT INTO public.")[1:]:
        table = re.match(r"(\w+)", chunk)
        if not table:
            continue
        rows.setdefault(table.group(1), []).extend(
            re.findall(r"^\s*\('([^']+)'", chunk, re.MULTILINE)
        )
    return rows


def main() -> int:
    problems: list[str] = []

    if not PACKS_FILE.is_file():
        print(f"FAIL: {PACKS_FILE} is missing")
        return 1

    packs = json.loads(PACKS_FILE.read_text(encoding="utf-8"))
    if not packs:
        problems.append("data-packs/packs.json defines no packs")

    seed_rows = (
        seed_rows_by_table(STARTER_SQL.read_text(encoding="utf-8"))
        if STARTER_SQL.is_file()
        else {}
    )
    if not seed_rows:
        problems.append("could not read any INSERT rows out of sql/seed-starter-dataset.sql")

    seen_ids: dict[str, str] = {}
    packed_tables: set[str] = set()

    for key, pack in packs.items():
        entity = pack.get("entity")
        code = pack.get("code")
        columns = pack.get("columns") or []
        label = f"pack '{key}'"

        for field in ("entity", "code", "title"):
            if not pack.get(field):
                problems.append(f"{label}: missing '{field}'")
        if not entity or not code:
            continue

        if code != f"data-pack-{key}":
            problems.append(f"{label}: code '{code}' should be 'data-pack-{key}'")
        if code in [p.get("code") for k, p in packs.items() if k != key]:
            problems.append(f"{label}: code '{code}' is not unique")

        if not columns:
            problems.append(f"{label}: has no columns")
            continue

        fields = [column.get("field") for column in columns]
        headers = [column.get("header") for column in columns]
        if len(set(fields)) != len(fields):
            problems.append(f"{label}: duplicate mapped field(s) in columns")
        if len(set(headers)) != len(headers):
            problems.append(f"{label}: duplicate CSV header(s) in columns")
        if not all(fields) or not all(headers):
            problems.append(f"{label}: every column needs both 'field' and 'header'")

        entity_def = entity_definition(entity)
        entity_fields: dict[str, dict] = entity_def.get("fields") or {}
        entity_links: dict[str, dict] = entity_def.get("links") or {}
        if not entity_fields:
            problems.append(f"{label}: metadata/entityDefs/{entity}.json is missing")

        for column in columns:
            field = column.get("field")
            if field in IMPLICIT_FIELDS:
                continue
            if entity_fields and field not in entity_fields:
                problems.append(f"{label}: '{field}' is not a field of {entity}")
                continue
            spec = entity_fields.get(field) or {}
            if spec.get("type") in RELATIONSHIP_TYPES:
                import_by = column.get("importBy")
                if not import_by:
                    problems.append(
                        f"{label}: relationship column '{field}' needs 'importBy' "
                        "(the attribute on the related entity to match by)"
                    )
                else:
                    problems.extend(
                        check_import_by(label, entity, field, import_by, entity_links)
                    )

        csv_path = PACKS_DIR / f"{entity}.csv"
        if not csv_path.is_file():
            problems.append(f"{label}: data-packs/{entity}.csv is missing")
            continue

        with csv_path.open(newline="", encoding="utf-8-sig") as handle:
            reader = csv.DictReader(handle)
            header = reader.fieldnames or []
            rows = [row for row in reader if any((value or "").strip() for value in row.values())]

        if header != headers:
            problems.append(
                f"{label}: {csv_path.name} header {header} does not match packs.json {headers}"
            )
            continue
        if not rows:
            problems.append(f"{label}: {csv_path.name} has no data rows")

        ids: list[str] = []
        for row in rows:
            row_id = (row.get("ID") or "").strip()
            if not row_id:
                problems.append(f"{label}: {csv_path.name} has a row without an ID")
                continue
            if not row_id.startswith("starter-"):
                problems.append(f"{label}: id '{row_id}' is not namespaced 'starter-'")
            if row_id in seen_ids:
                problems.append(f"{label}: id '{row_id}' is already used by {seen_ids[row_id]}")
            seen_ids[row_id] = label
            ids.append(row_id)

        table = snake_case(entity)
        packed_tables.add(table)
        seed_ids = list(seed_rows.get(table, []))
        if not seed_ids:
            problems.append(
                f"{label}: sql/seed-starter-dataset.sql writes no rows to '{table}', so the two "
                "onboarding paths cannot agree — add the rows there or drop the pack"
            )
        elif sorted(ids) != sorted(seed_ids):
            only_pack = sorted(set(ids) - set(seed_ids))
            only_seed = sorted(set(seed_ids) - set(ids))
            problems.append(
                f"{label}: {table} ids differ from the starter seed "
                f"(only in packs: {only_pack or '—'}; only in seed: {only_seed or '—'})"
            )

    for table, ids in seed_rows.items():
        if table in packed_tables or table in SEED_TABLES_WITHOUT_PACKS:
            continue
        problems.append(
            f"sql/seed-starter-dataset.sql writes to '{table}' ({len(ids)} row(s)) but no data "
            "pack covers it — add a pack or list the table in SEED_TABLES_WITHOUT_PACKS"
        )

    if problems:
        print("FAIL: data packs are inconsistent:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    total_rows = sum(
        len(list(csv.DictReader((PACKS_DIR / f"{pack['entity']}.csv").open(encoding="utf-8-sig"))))
        for pack in packs.values()
    )
    print(
        f"OK: data packs valid — {len(packs)} packs, {total_rows} rows, ids and columns match "
        "sql/seed-starter-dataset.sql"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
