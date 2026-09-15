#!/usr/bin/env python3
"""Validate the committed demo dataset without needing a database.

`sql/seed-demo-dataset.sql` is applied to a *live* AtroCore database, which CI
cannot currently provide: the `atro-web` image built in this pipeline starts
Apache with a DocumentRoot that does not exist, i.e. the AtroCore application is
never installed, so its schema is never created and there is nothing to seed.
(The old `demo_seed_check` job sidestepped that by skipping itself whenever
`atrocore.dump` was absent — which, since dumps are gitignored, was every run.)

So this checks the invariants that matter for a *committed* seed and that a
database would only catch late:

1. Nothing destructive outside the demo rows. Every DELETE must be scoped to
   `id LIKE 'demo-%'` and there must be no TRUNCATE or unscoped DELETE — the
   whole point is that this seed is safe against a database holding real
   records.
2. Every table touched is one of the known demo tables, and every row id starts
   with `demo-`.
3. The row count still matches the documented total, so the docs and the CI
   assertion elsewhere cannot silently drift from the file.
4. `--remove` cannot miss a table: the DEMO_TABLES array in
   `scripts/seed-demo-dataset.sh` must cover exactly the tables the SQL deletes
   from. Adding a table to the seed without adding it there would leak rows.

The live apply is verified by hand against a running stack (see the CHANGELOG
entry) and documented in the README quickstart.

Usage: python3 scripts/validate-demo-seed.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL_FILE = ROOT / "sql" / "seed-demo-dataset.sql"
SH_FILE = ROOT / "scripts" / "seed-demo-dataset.sh"

# Documented in the SQL header, the README and the MR description.
EXPECTED_DEMO_ROWS = 38

problems: list[str] = []

if not SQL_FILE.is_file():
    print(f"FAIL: {SQL_FILE} is missing")
    sys.exit(1)

sql = SQL_FILE.read_text(encoding="utf-8")

# --- 1. nothing destructive outside the demo rows ---------------------------
if re.search(r"\bTRUNCATE\b", sql, re.IGNORECASE):
    problems.append("the seed uses TRUNCATE; it must only ever touch demo- rows")

delete_tables: set[str] = set()
for match in re.finditer(r"DELETE\s+FROM\s+(?:public\.)?(\w+)\s*(.*?);", sql, re.IGNORECASE | re.DOTALL):
    table, clause = match.group(1), match.group(2)
    delete_tables.add(table)
    if not re.search(r"id\s+LIKE\s+'demo-%'", clause, re.IGNORECASE):
        problems.append(
            f"DELETE FROM {table} is not scoped to demo- rows "
            f"({re.sub(r'\\s+', ' ', clause).strip()[:70]})"
        )

# --- 2. only known tables, only demo- ids -----------------------------------
insert_tables = set(re.findall(r"INSERT\s+INTO\s+(?:public\.)?(\w+)", sql, re.IGNORECASE))

if not insert_tables:
    problems.append("the seed contains no INSERT statements")

if insert_tables != delete_tables:
    only_insert = insert_tables - delete_tables
    only_delete = delete_tables - insert_tables
    if only_insert:
        problems.append(f"INSERT without a matching scoped DELETE: {sorted(only_insert)}")
    if only_delete:
        problems.append(f"DELETE without a matching INSERT: {sorted(only_delete)}")

row_ids = re.findall(r"^\s*\('([^']+)'", sql, re.MULTILINE)
for row_id in row_ids:
    if not row_id.startswith("demo-"):
        problems.append(f"seed row id does not start with demo-: {row_id}")

# --- 3. the row count still matches the documentation ------------------------
if len(row_ids) != EXPECTED_DEMO_ROWS:
    problems.append(
        f"expected {EXPECTED_DEMO_ROWS} demo rows, counted {len(row_ids)} — "
        "update EXPECTED_DEMO_ROWS, the SQL header, the README and the CHANGELOG together"
    )

# --- 4. --remove must cover every table the seed writes ---------------------
if not SH_FILE.is_file():
    problems.append(f"{SH_FILE} is missing")
else:
    shell = SH_FILE.read_text(encoding="utf-8")
    block = re.search(r"DEMO_TABLES=\((.*?)\)", shell, re.DOTALL)
    if not block:
        problems.append("could not find the DEMO_TABLES array in scripts/seed-demo-dataset.sh")
    else:
        remove_tables = set(re.findall(r"\w+", block.group(1)))
        missing = insert_tables - remove_tables
        extra = remove_tables - insert_tables
        if missing:
            problems.append(f"DEMO_TABLES does not cover: {sorted(missing)} — --remove would leak rows")
        if extra:
            problems.append(f"DEMO_TABLES lists tables the seed never writes: {sorted(extra)}")

# --- 5. no secrets / real-looking data --------------------------------------
for pattern, why in (
    (r"password\s*[:=]", "looks like it contains a password"),
    (r"@(?!demo-)[a-z0-9.-]+\.(?:com|org|net|gov)\b", "contains a routable e-mail domain (use .invalid)"),
):
    if re.search(pattern, sql, re.IGNORECASE):
        problems.append(f"the seed {why}")

if problems:
    print(f"FAIL: {len(problems)} problem(s) in the demo seed:")
    for problem in problems:
        print(f"  - {problem}")
    sys.exit(1)

print(
    f"OK: demo seed is additive and consistent — {len(row_ids)} rows across "
    f"{len(insert_tables)} tables, every DELETE scoped to demo- rows, "
    f"--remove covers every table."
)
