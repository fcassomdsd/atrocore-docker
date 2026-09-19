# Authority data packs

CSV templates that load an authority's own records into AtroCore **through AtroCore's import
module** — the same records `sql/seed-starter-dataset.sql` seeds, in the one format an adopter can
edit in a spreadsheet and re-import whenever the data changes.

Nine kinds of authority record have to exist before an inspection can be planned — locations,
service providers, contacts, inspectors, service areas, assignment groups, regulations and their
articles, and the location↔provider services that tie them together. Hand-entering them through
the admin UI is the slowest part of standing the platform up, and a SQL seed cannot be edited by
someone who does not write SQL. A pack is a CSV template plus the column mapping AtroCore needs,
so the work becomes: open the CSV, replace the placeholders, import.

## Quick start

```bash
cd atrocore-docker

make db-seed-vocabularies YES=1     # reference catalogs the packs point at (specialty, activity type)
make import-data-packs              # every pack
make import-data-packs PACK=location        # one pack
make import-data-packs PACK="location inspector"
./scripts/import-data-pack.py --list        # what is available
./scripts/import-data-pack.py --all --dry-run
```

Credentials come from `../compliance_flow/.env` (`ATROCORE_USERNAME` / `ATROCORE_PASSWORD`) or this
repo's `.env`; the API host is `ATROCORE_API_BASE`, then `DEMO_HOST` (default `localhost`). The
stack must be up and the metadata installed.

## The packs

| Pack | Entity | CSV | What it is |
|---|---|---|---|
| `location` | Location | `Location.csv` | Aerodromes/sites, identified by their ICAO code |
| `service-provider` | ServiceProvider | `ServiceProvider.csv` | The organisations that are inspected |
| `service-area` | ServiceArea | `ServiceArea.csv` | Broad service groupings |
| `person` | Person | `Person.csv` | Points of contact at a provider |
| `inspector` | Inspector | `Inspector.csv` | Your inspectors and their specialties |
| `assignment-group` | AssignmentGroup | `AssignmentGroup.csv` | Groups inspectors are assigned through |
| `reglamento` | Reglamento | `Reglamento.csv` | A regulation (the instrument) |
| `normativa` | Normativa | `Normativa.csv` | Articles of a regulation, each linked to its `reglamento` |
| `location-service` | LocationService | `LocationService.csv` | A provider's service at a location, with its contact and area |

Import them **in the order listed** (it is the order in `data-packs/packs.json`): later packs
reference rows earlier ones create. `--all` does this for you. A pack imported before its
dependencies reports a clear `no record(s) found in the entity 'X' with: {...}` error.

`InspectionCadence` is deliberately **not** a pack. Its `inspectedProvider` field is a required
link to `InspectedProvider`, which is an operational record created per site visit, not authority
data — so a cadence cannot exist until a site visit has been planned. Create cadences in the admin
UI at that point; to bulk-load them later, copy `packs.json`'s shape, point the new feed at
`InspectionCadence`, and use the ids of the `InspectedProvider` rows you already have.

## Editing a template

Replace the placeholder values, keep the header row (the headers are what the mapping matches), and
re-run the same command. Rows are matched by their `ID` column and upserted
(`fileDataAction=create_update`), so an import never duplicates a row and a re-import of unchanged
data writes nothing.

* Every id is namespaced `starter-` so the whole dataset can be removed with
  `make db-seed-starter-remove YES=1`. If you are typing real records, use your own ids — a row you
  create is never touched by the removal, and the seed never overwrites a row you have edited.
* Extra columns are fine: add a column to the CSV *and* a matching entry to the pack's `columns` in
  `data-packs/packs.json` (field name from `metadata/entityDefs/<Entity>.json`, header, and for a
  link the `importBy` attribute to match the related record by). A column the pack stops mapping is
  pruned from the feed automatically, so a removed column cannot keep writing its old default.
* A relationship cell is matched by `importBy` — `id` for rows you created here, `code` for the
  reference catalogs (e.g. `ATS` for a specialty). An empty relationship cell leaves the link
  alone.
* Values with commas must be quoted (standard CSV) — see `Normativa.csv`, whose article texts are
  quoted for that reason.

## How it works

`scripts/import-data-pack.py` performs the parts of the import UI that would otherwise have to be
clicked through, then runs the import:

1. ensures an `ImportFeed` for the pack's entity (idempotent, keyed on the feed `code`);
2. ensures one `ImportConfiguratorItem` per mapped column, and removes items the pack no longer
   maps;
3. converts the CSV rows to JSON keyed by the CSV headers;
4. runs `POST /api/v1/ImportFeed/action/easyCatalog` with `{code, json: [...]}` — no file upload
   needed;
5. polls the resulting `ImportJob` and prints the outcome, with one line per failure.

The exit status is non-zero if any pack reports an import error, so it gates CI. The whole flow is
also what the `fresh-install` CI job exercises on an empty database after applying the seed, which
is how a pack whose links or required fields no longer fit the metadata gets caught before a user
meets it.

`scripts/validate-data-packs.py` is the container-free half of the contract: it checks the mapping
against `metadata/entityDefs/`, the CSV headers against `packs.json`, the `starter-` namespacing, and
that each pack's ids are **exactly** the ids `sql/seed-starter-dataset.sql` writes for that entity —
so the SQL seed and the import path cannot drift apart.

## Relationship to the other datasets

| Dataset | Purpose | How it is applied |
|---|---|---|
| `demo-` (`sql/seed-demo-dataset.sql`) | Synthetic data for the whole-platform quickstart | `make db-seed-demo YES=1` |
| `starter-` (`sql/seed-starter-dataset.sql`) | Placeholder authority records to edit | `make db-seed-starter YES=1` |
| data packs (`data-packs/`) | The same `starter-` records as editable CSV, loaded through the import module | `make import-data-packs` |

Use the starter seed *or* the packs, not both — they write the same rows. Applying both is
harmless (the second is a no-op) and is what CI does to prove they agree.
