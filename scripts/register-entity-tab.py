#!/usr/bin/env python3
"""Register an entity in an AtroCore config.php `tabList` / `quickCreateList`.

AtroCore stores its navigation in `web-data/<domain>/data/config.php` as PHP
arrays with explicit integer keys:

    'tabList' => [
        0 => 'RegulatoryDocument',
        ...
        34 => 'UsoapProtocolQuestion'
    ],

Adding an entry by hand means renumbering by hand, so this script appends the
entity to each list and keeps the numbering contiguous. It is idempotent:
running it twice is a no-op.

`config.php` lives under the gitignored, container-managed `web-data/` tree, so
it cannot be version-controlled directly -- this script is the reproducible
way to reapply the change after a clean checkout or a container rebuild.

Usage: register-entity-tab.py <config.php> <EntityName> [EntityName ...]
"""

import re
import sys

LISTS = ("tabList", "quickCreateList")


def register(text: str, list_name: str, entity: str) -> tuple[str, bool]:
    """Append `entity` to the named PHP list, renumbering keys contiguously."""
    pattern = re.compile(
        r"(?P<head>'" + re.escape(list_name) + r"'\s*=>\s*\[)(?P<body>.*?)(?P<tail>\n(?P<indent>\s*)\],)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        print(f"  warning: '{list_name}' not found; skipped", file=sys.stderr)
        return text, False

    body = match.group("body")
    items = re.findall(r"\d+\s*=>\s*'([^']*)'", body)

    if entity in items:
        print(f"  {list_name}: '{entity}' already registered")
        return text, False

    items.append(entity)

    # Reuse the indentation of the existing entries so the file keeps its shape.
    entry_indent_match = re.search(r"\n(\s*)\d+\s*=>", body)
    entry_indent = entry_indent_match.group(1) if entry_indent_match else "        "

    rendered = "".join(
        f"\n{entry_indent}{i} => '{name}'," for i, name in enumerate(items)
    ).rstrip(",")

    new_text = text[: match.start()] + match.group("head") + rendered + match.group("tail") + text[match.end():]
    print(f"  {list_name}: added '{entity}' at index {len(items) - 1}")
    return new_text, True


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1

    config_path = sys.argv[1]
    entities = sys.argv[2:]

    with open(config_path, encoding="utf-8") as handle:
        text = handle.read()

    original = text
    for entity in entities:
        for list_name in LISTS:
            text, _ = register(text, list_name, entity)

    if text == original:
        print("  config.php unchanged")
        return 0

    with open(config_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"  updated {config_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
