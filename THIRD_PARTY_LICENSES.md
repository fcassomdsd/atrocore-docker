# Third-party licenses

This repository's own files (Docker Compose configuration, scripts, seed SQL, documentation) are licensed under Apache License 2.0 — see `NOTICE`. **This does not extend to the AtroCore application itself**, which this repository installs at runtime, not at build time — see below.

## ⚠️ AtroCore core and its first-party extensions are GPL-3.0-only

This is the single most consequential licensing fact about this repository, confirmed by reading the license files bundled with the packages themselves (`composer.json`'s `license` field is missing on several of them — the `LICENSE.txt` in each package directory is the actual source of truth):

| Composer package | Version pinned (`composer.pinned.json`) | License (confirmed from bundled `LICENSE.txt`) |
|---|---|---|
| `atrocore/core` | 2.1.6 | **GPL-3.0-only** |
| `atrocore/atrocore-legacy` | ~1.2.0 | **GPL-3.0-only** (identical license text to `core`) |
| `atrocore/export` | 1.10.1 | **GPL-3.0-only** (identical license text to `core`) |
| `atrocore/import` | 1.10.2 | **GPL-3.0-only** (identical license text to `core`) |
| `atrocore/export-http` | 1.8.0 | **GPL-3.0-only** (identical license text to `core`) |
| `atrocore/import-http` | 1.6.1 | **GPL-3.0-only** (identical license text to `core`) |
| `atrocore/slim` | ~2.6.2 | MIT (the one exception — a Slim Framework–derived dependency of `core`) |

### Mitigation shipped: these packages are no longer baked into the `atro-web` image

Until this cycle, these packages were pulled from `https://packagist.atrocore.com` **during the Docker image build** (`.docker/php/scripts/prepare-pim.sh`, invoked from `.docker/php/Dockerfile`'s `RUN` step) and compiled directly into the built `atro-web` image — unambiguous "distribution" under GPL-3.0 §6 the moment that image was ever published pre-built. That is no longer how this works: `prepare-pim.sh`'s AtroCore-install sequence now runs at **container bootstrap** (`scripts/bootstrap-web-data.sh`, invoked at first `docker compose up`), inside a throwaway container, writing the installed application into the bind-mounted `./web-data/` on the adopter's own machine — never into the image's own build layers. Verified directly: the built `atro-web` image contains no `vendor/atrocore/*` anywhere in its filesystem; only the generic PHP+Apache+extensions base and the (unmodified) install scripts themselves.

This changes the posture to something much closer to how `compliance_cmis`'s Alfresco containers are already treated: each adopter's own container pulls AtroCore's GPL-3.0 source directly from AtroCore's own public upstream, at their own first startup, on their own machine — not something this repository builds and could redistribute. **It does not resolve every open question below** — the underlying GPL-3.0 terms on AtroCore's own code are unchanged, and questions 1–3 are unaffected by *when* the Composer install runs. It specifically closes question 4: there is no longer a "should we publish pre-built images" decision to make, because there is no longer anything GPL-flavored in the image to publish.

**Still a real, open item for legal review** — LGPL (Alfresco) is a weak copyleft that mainly concerns *linking*; GPL-3.0 (AtroCore) is the strong copyleft that concerns the whole combined/derivative work, and that doesn't change just because the code isn't compiled into a binary artifact anymore. Specific questions for legal review (in addition to the Alfresco ones):

1. Do `atrocore-docker`'s own scripts and configuration (which install, configure, and orchestrate AtroCore, but don't modify its source) constitute a "combined work" with the GPL-3.0 code, or does GPL-3.0's "mere aggregation" carve-out apply to a Docker Compose setup that treats AtroCore as an installed application rather than a linked library?
2. Does this repository's own tracked `metadata/` overlay (entity definitions, layouts — recovered and tracked as of `atrocore-docker!` P2.6 this cycle) constitute a derivative work of the GPL-3.0 core, given it's data/config consumed by AtroCore's own extension mechanism rather than modified AtroCore source code?
3. Given `atrocore/atrocore-legacy`, `export`, `import`, `export-http`, `import-http` don't declare a license in their own `composer.json` (only in a bundled `LICENSE.txt`), is there any ambiguity about which license actually governs them, or does the bundled file control regardless?
4. ~~If Workstream 5's "publish pre-built images" option is ever taken, what GPL-3.0 compliance is required at that point...~~ — **moot as of this cycle.** The `atro-web` image no longer contains GPL-3.0 code in any layer, so there is nothing to require compliance for even if a pre-built image were published. Confirmed by direct inspection of the built image's filesystem.

## Worst-case scenario: is the tracked `metadata/` overlay a derivative work?

Worked through here as a best-faith walkthrough of GPL-3.0's actual mechanics, not legal advice — the point is to size the exposure before commissioning review. This is the GPL-3.0 counterpart to the same kind of question worked through for the Alfresco LGPL-3.0 images in `compliance_cmis/THIRD_PARTY_LICENSES.md`, and the comparison matters: **GPL-3.0 has no equivalent to LGPL's built-in "combine and keep your own license" permission**, so this worst case is genuinely more severe than the Alfresco one, not just a mirror of it.

`metadata/`'s `entityDefs`/`clientDefs`/`scopes`/`layouts` are JSON files declaring custom entity schemas, field types, relationships and layouts, loaded and interpreted directly by AtroCore's own (unmodified) PHP classes at runtime — the extension mechanism AtroCore itself is built around and documents. No AtroCore source code is copied into these files.

**Best case**: pure declarative data that AtroCore's own code reads — analogous to a config file or a set of user-supplied values, not source code that extends or subclasses AtroCore's internals. GPL-3.0 §5's "aggregate" carve-out (works that are merely aggregated alongside a GPL program, without being combined into it to form a single program, stay under their own license) plausibly covers this.

**Worst case**: an aggressive reading argues the entityDefs/clientDefs schema structure (field names, types, layout-DSL conventions) is itself substantially defined by — arguably a structural mirror of — AtroCore's own internal domain-model classes, and that these files become part of AtroCore's live in-memory object model at runtime once loaded, which is tighter coupling than "aggregation." Under that reading, `metadata/` would be found a "work based on the Program" under GPL-3.0 §5, not qualifying for the aggregate carve-out.

**What the worst case actually requires — and where it's contained, not open-ended:**

- **Narrow worst case (most likely, if any)**: only the `metadata/` files themselves (JSON, already plaintext, no compiled form — "source" and "distributed form" are already the same thing here) would need to be conveyed under GPL-3.0 terms rather than this repository's Apache-2.0. Mechanically simple: the files are already published as-is, so the practical burden is closer to a relicensing/notice change than a new disclosure obligation.
- **Broad worst case (weaker argument, more severe)**: if `metadata/` were found to be part of the *same combined program* as AtroCore rather than a severable, independently-copyrightable component merely aggregated alongside it, GPL-3.0 §5's "the whole work must be conveyed under this License, to everyone" logic could theoretically extend to this repository's other original content (scripts, seed SQL, documentation) — losing Apache-2.0 on this project's own work, the same severity of outcome the bootstrap-time-install fix above was specifically designed to avoid for the compiled application code. This reading is considerably weaker than the narrow one: scripts, SQL, and `docker-compose.yml` are never loaded or interpreted by AtroCore's own runtime at all (they're external tooling operating *on* AtroCore, not data AtroCore's PHP classes parse), which is a much cleaner "aggregate" case than `metadata/` itself.

**Net read**: unlike the Alfresco LGPL worst case (which converges on a documentation/notice task regardless of which way the derivative-work question is found), this GPL-3.0 worst case has a real, non-trivial tail: relicensing `metadata/` specifically is a contained, mechanical fix if it happens, but the broader "whole repository" reading — while a weaker legal argument — is the more consequential one to have counsel rule out explicitly rather than assume away.

## Other container images

| Image | Upstream project/vendor | License source |
|---|---|---|
| postgres:15-alpine | PostgreSQL Global Development Group | PostgreSQL License |
| php:8.4-apache-bookworm (base image) | PHP Group / Debian | PHP License + Debian package licenses |

## How to maintain this file

1. Re-verify the AtroCore package licenses above whenever `composer.pinned.json` changes versions — a version bump could, in principle, change licensing terms.
2. Add new third-party libraries or images when introduced.
3. Link to the canonical license source where possible.
4. Preserve required attribution and notice text when redistributing.

## Important note

This file is an operational tracking document, not legal advice. The GPL-3.0 finding above is a **factual report of what the bundled license files say**, not a legal conclusion about what it obligates this project to do.
For commercial redistribution or productization — and especially before any public/open-source release of this repository — perform a legal review of all third-party license obligations, with the AtroCore GPL-3.0 question above as the priority item.
