#!/usr/bin/env python3
"""Import an authority data pack into AtroCore through AtroCore's own import module.

A pack is a CSV template under `data-packs/` plus its definition in `data-packs/packs.json`
(which entity, which columns map to which fields, and how link columns are matched). This
script does the parts an adopter would otherwise have to learn in the import UI:

  1. ensures an ImportFeed exists for the pack's entity (and keeps it up to date);
  2. ensures one ImportConfiguratorItem per mapped column;
  3. reads the CSV, converts each row to a JSON object keyed by the CSV headers;
  4. runs the import through `POST /api/v1/ImportFeed/action/easyCatalog`;
  5. waits for the resulting ImportJob and prints its outcome.

It is idempotent: feeds use `fileDataAction=create_update`, so re-importing an edited CSV
updates the rows whose identifier it already knows and creates the rest. The exit status is
non-zero if any pack reports an import error, so it can gate CI.

Usage:
    scripts/import-data-pack.py --list
    scripts/import-data-pack.py location
    scripts/import-data-pack.py --all
    scripts/import-data-pack.py location --file my-locations.csv
    scripts/import-data-pack.py --all --dry-run

Credentials come from ../compliance_flow/.env or this repo's .env (ATROCORE_USERNAME /
ATROCORE_PASSWORD), and the host from DEMO_HOST (default localhost).
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKS_DIR = ROOT / "data-packs"
PACKS_FILE = PACKS_DIR / "packs.json"

# Feed fields that make a pack behave as an editable, re-runnable upsert.
FEED_DEFAULTS = {
    "type": "simple",
    "processingType": "configurator",
    "format": "JSON",
    "repeatProcessing": "repeat",
    "fileDataAction": "create_update",
    "decimalMark": ".",
    "delimiter": ",",
    "fieldDelimiterForRelation": "|",
    "isActive": True,
}


def read_env() -> dict[str, str]:
    """compliance_flow/.env first (AtroCore credentials), then this repo's .env, then the
    real environment, so an explicit variable always wins."""
    env: dict[str, str] = {}
    for path in (ROOT.parent / "compliance_flow" / ".env", ROOT / ".env"):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")
    env.update(os.environ)
    return env


class Client:
    def __init__(self, env: dict[str, str]):
        host = env.get("DEMO_HOST") or "localhost"
        self.api = env.get("ATROCORE_API_BASE") or f"http://{host}/api/v1"
        self.user = env.get("ATROCORE_USERNAME")
        self.password = env.get("ATROCORE_PASSWORD")
        if not self.user or not self.password:
            sys.exit(
                "Error: ATROCORE_USERNAME / ATROCORE_PASSWORD are not set "
                "(looked in ../compliance_flow/.env and .env)."
            )

    def _call(self, method: str, path: str, body=None, token=None, token_header="Authorization"):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.api + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header(token_header, token)
        else:
            raw = f"{self.user}:{self.password}".encode("utf-8")
            req.add_header("Authorization", "Basic " + base64.b64encode(raw).decode())
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise SystemExit(f"Error: HTTP {exc.code} on {method} {path}: {detail}")

    def login(self) -> str:
        result = self._call("GET", "/App/user")
        token = (result or {}).get("authorizationToken")
        if not token:
            raise SystemExit("Error: could not obtain an AtroCore token from /App/user.")
        self.token = token
        return token

    def entity(self, method, path, body=None):
        # AtroCore's OpenAPI declares two schemes. `Authorization: Bearer <token>` accepts the
        # same token but is rejected intermittently (HTTP 401, empty body) once another client
        # has used it; the apiKey header `Authorization-Token` is accepted consistently for both
        # entity CRUD and action routes, so use it everywhere (see Atro\Core\OpenApiGenerator).
        return self._call(method, path, body, token=self.token, token_header="Authorization-Token")

    def action(self, action, body):
        return self._call("POST", f"/ImportFeed/action/{action}", body, token=self.token,
                          token_header="Authorization-Token")


def find_one(client: Client, entity: str, pairs: dict[str, str]) -> dict | None:
    query = {}
    for index, (attribute, value) in enumerate(pairs.items()):
        query[f"where[{index}][type]"] = "equals"
        query[f"where[{index}][attribute]"] = attribute
        query[f"where[{index}][value]"] = value
    query["maxSize"] = "1"
    result = client.entity("GET", f"/{entity}?{urllib.parse.urlencode(query)}")
    rows = (result or {}).get("list") or []
    return rows[0] if rows else None


def ensure_feed(client: Client, pack: dict) -> str:
    payload = {"name": f"Data pack: {pack['title']}", "code": pack["code"], "entity": pack["entity"]}
    payload.update(FEED_DEFAULTS)
    existing = find_one(client, "ImportFeed", {"code": pack["code"]})
    if existing:
        client.entity("PATCH", f"/ImportFeed/{existing['id']}", payload)
        return existing["id"]
    created = client.entity("POST", "/ImportFeed", payload)
    return created["id"]


def ensure_items(client: Client, feed_id: str, columns: list[dict]) -> None:
    # A collection GET /ImportConfiguratorItem is answered with HTTP 403 (its ACL class checks
    # every row against the parent feed, which a scope-level list request cannot satisfy), so
    # read the rows through the parent's hasMany link instead and address them by id.
    result = client.entity("GET", f"/ImportFeed/{feed_id}/configuratorItems?maxSize=200")
    existing_by_name = {row["name"]: row["id"] for row in (result or {}).get("list") or []}
    wanted = {column["field"] for column in columns}
    # Prune columns the pack no longer maps: a leftover item keeps writing its default ('' for a
    # text field) on every import, which turns an otherwise unchanged row into an update.
    for name, item_id in existing_by_name.items():
        if name not in wanted:
            client.entity("DELETE", f"/ImportConfiguratorItem/{item_id}")
    for column in columns:
        item = {
            "name": column["field"],
            "column": [column["header"]],
            "importBy": column.get("importBy") or [column["field"]],
            "entityIdentifier": bool(column.get("identifier")),
            "importFeedId": feed_id,
        }
        existing_id = existing_by_name.get(column["field"])
        if existing_id:
            client.entity("PATCH", f"/ImportConfiguratorItem/{existing_id}", item)
        else:
            client.entity("POST", "/ImportConfiguratorItem", item)


def read_rows(path: Path, columns: list[dict]) -> list[dict]:
    headers = {c["header"] for c in columns}
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        missing = headers - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(f"Error: {path.name} is missing column(s): {sorted(missing)}")
        rows = []
        for raw in reader:
            row = {header: (raw.get(header) or "").strip() for header in headers}
            if any(row.values()):
                rows.append(row)
    return rows


def newest_job(client: Client, feed_id: str) -> dict | None:
    # The collection endpoint ignores `orderBy`/`order` (it returns an arbitrary order), so the
    # newest job has to be picked client-side. `sortOrder` is the module's creation timestamp.
    result = client.entity(
        "GET",
        f"/ImportJob?{urllib.parse.urlencode({'where[0][type]': 'equals', 'where[0][attribute]': 'importFeedId', 'where[0][value]': feed_id, 'maxSize': '200'})}",
    )
    jobs = (result or {}).get("list") or []
    if not jobs:
        return None
    return max(jobs, key=lambda job: (job.get("sortOrder") or 0, job.get("createdAt") or ""))


def latest_job_id(client: Client, feed_id: str) -> str | None:
    return (newest_job(client, feed_id) or {}).get("id")


def wait_for_job(
    client: Client, feed_id: str, previous_id: str | None, timeout: float = 300.0, grace: float = 40.0
) -> dict | None:
    """Wait for the job `easyCatalog` starts.

    AtroCore's job runner picks queued jobs up on a ~60s tick, so a pack can take a minute to
    finish. An import whose rows are all already up to date starts no job at all, so a job only
    counts as ours when its id differs from the newest one seen before the action; `grace` is how
    long to wait for that id to appear before concluding nothing changed."""
    start = time.time()
    while True:
        job = newest_job(client, feed_id)
        if job and job.get("id") != previous_id:
            if job.get("state") in ("Success", "Failed", "Canceled"):
                return job
            if time.time() - start > timeout:
                raise SystemExit(
                    f"Error: timed out after {timeout:.0f}s waiting for import job "
                    f"{job['id']} on feed {feed_id} (state {job.get('state')})."
                )
        elif time.time() - start > grace:
            return None
        time.sleep(2)


JOB_LOG_TYPES = ("create", "update", "skip", "error")


def _job_log_total(client: Client, job_id: str, kind: str | None = None) -> int:
    """How many ImportJobLog rows this job has, optionally of one type.

    The count comes from the collection's `total`, not from the returned rows: the API returns
    rows in an arbitrary order and a large pack logs thousands of them, so counting a capped page
    would under-report — and, worse, would let a row error beyond the page go unnoticed."""
    query = {"where[0][type]": "equals", "where[0][attribute]": "importJobId",
             "where[0][value]": job_id, "maxSize": "1"}
    if kind:
        query.update({"where[1][type]": "equals", "where[1][attribute]": "type", "where[1][value]": kind})
    result = client.entity("GET", f"/ImportJobLog?{urllib.parse.urlencode(query)}")
    return int((result or {}).get("total") or 0)


def summarise(client: Client, job_id: str) -> tuple[dict[str, int], list[str]]:
    counts = {kind: _job_log_total(client, job_id, kind) for kind in JOB_LOG_TYPES}
    counts = {kind: total for kind, total in counts.items() if total}

    errors: list[str] = []
    if counts.get("error"):
        # Fetch the messages themselves (bounded), but trust the total above for the count, so a
        # failing import is never reported as a success just because the page was full.
        result = client.entity(
            "GET",
            f"/ImportJobLog?{urllib.parse.urlencode({'where[0][type]': 'equals', 'where[0][attribute]': 'importJobId', 'where[0][value]': job_id, 'where[1][type]': 'equals', 'where[1][attribute]': 'type', 'where[1][value]': 'error', 'maxSize': '200'})}",
        )
        for row in (result or {}).get("list") or []:
            message = (row.get("message") or "no message").strip()
            errors.append(f"row {row.get('rowNumber')}: {message}")
        if counts["error"] > len(errors):
            errors.append(f"... and {counts['error'] - len(errors)} more error(s) not shown")

    logged = sum(counts.values())
    all_logs = _job_log_total(client, job_id)
    if all_logs > logged:
        counts["other"] = all_logs - logged
    return counts, errors


def submit_pack(client: Client, key: str, pack: dict, csv_path: Path) -> tuple[str, str | None] | None:
    """Ensure the feed/columns and hand the CSV rows to the import module. Returns the feed id
    and the newest job id seen before submitting, so a later job can be told apart from an old
    one. The job itself is collected separately so `--all` can queue every pack before waiting.
    Returns None when the CSV carries no data rows — an empty template has nothing to import and
    submitting it would only create a job with no log rows."""
    rows = read_rows(csv_path, pack["columns"])
    if not rows:
        print(f"  {key}: {csv_path.name} has no data rows — nothing to import")
        return None
    print(f"  {key}: {len(rows)} row(s) from {csv_path.name}")
    feed_id = ensure_feed(client, pack)
    ensure_items(client, feed_id, pack["columns"])
    previous_job = latest_job_id(client, feed_id)
    client.action("easyCatalog", {"code": pack["code"], "json": rows})
    return feed_id, previous_job


def collect_pack(client: Client, key: str, feed_id: str, previous_job: str | None) -> bool:
    """Wait for a submitted pack's job and report its outcome; True when it fully succeeded."""
    job = wait_for_job(client, feed_id, previous_job)
    if job is None:
        print(f"  {key}: feed {feed_id} · no job started (every row already up to date)")
        return True
    counts, errors = summarise(client, job.get("id", ""))
    summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "no log rows"
    print(f"  {key}: feed {feed_id} · job {job.get('state', 'unknown')} · {summary}")
    for message in errors:
        print(f"      ! {message}")
    return job.get("state") == "Success" and not errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("packs", nargs="*", help="pack key(s); see --list")
    parser.add_argument("--all", action="store_true", help="import every pack")
    parser.add_argument("--list", action="store_true", help="list the available packs and exit")
    parser.add_argument("--file", help="import this CSV instead of data-packs/<Entity>.csv")
    parser.add_argument("--dry-run", action="store_true", help="show what would be imported")
    args = parser.parse_args()

    packs = json.loads(PACKS_FILE.read_text(encoding="utf-8"))

    if args.list:
        for key, pack in packs.items():
            print(f"  {key:20} {pack['entity']:18} data-packs/{pack['entity']}.csv")
        return 0

    keys = list(packs) if args.all else args.packs
    if not keys:
        parser.error("name a pack, or pass --all (see --list)")

    unknown = [k for k in keys if k not in packs]
    if unknown:
        raise SystemExit(f"Error: unknown pack(s): {', '.join(unknown)} (see --list)")

    if args.file and len(keys) != 1:
        raise SystemExit("Error: --file applies to a single pack.")

    client = None if args.dry_run else Client(read_env())
    if client:
        client.login()

    print(f"Importing {len(keys)} data pack(s)" + (" (dry run)" if args.dry_run else "") + ":")
    submitted: list[tuple[str, str, str | None]] = []
    for key in keys:
        pack = packs[key]
        csv_path = Path(args.file) if args.file else PACKS_DIR / f"{pack['entity']}.csv"
        if not csv_path.is_file():
            raise SystemExit(f"Error: {csv_path} not found.")
        if args.dry_run:
            rows = read_rows(csv_path, pack["columns"])
            print(f"  {key}: {len(rows)} row(s) from {csv_path.name}")
            print(f"    [dry-run] would ensure feed {pack['code']} ({pack['entity']}) and import")
            continue
        result = submit_pack(client, key, pack, csv_path)
        if result is not None:
            feed_id, previous_job = result
            submitted.append((key, feed_id, previous_job))

    failures = 0
    for key, feed_id, previous_job in submitted:
        if not collect_pack(client, key, feed_id, previous_job):
            failures += 1

    if failures:
        print(f"{failures} of {len(keys)} data pack(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
