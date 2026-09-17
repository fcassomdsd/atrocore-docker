# Third-party licenses

This repository's own files (Docker Compose configuration, scripts, seed SQL, documentation) are licensed under Apache License 2.0 — see `NOTICE`. **This does not extend to the AtroCore application itself**, which this repository builds an image around and installs at runtime.

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

These packages are pulled from `https://packagist.atrocore.com` during the Docker image build (`.docker/php/scripts/composer.pinned.json`, driven by `prepare-pim.sh`) and are **baked into the built `atro-web` image**, not merely referenced at runtime the way `compliance_cmis`'s Alfresco containers are. That distinction matters: publishing this repository's build instructions is one thing, but publishing (or letting adopters pull) a **pre-built image containing compiled/assembled GPL-3.0 code** is unambiguously "distribution" under GPL-3.0 §6, triggering its source-availability and license-notice obligations for at least the AtroCore portion of the image.

**This is a materially bigger open item than the Alfresco LGPL question already on record in `compliance_cmis/THIRD_PARTY_LICENSES.md`** — LGPL is a weak copyleft that mainly concerns *linking*; GPL-3.0 is the strong copyleft that concerns the whole combined/derivative work. Specific questions for legal review (in addition to the Alfresco ones):

1. Do `atrocore-docker`'s own scripts and configuration (which install, configure, and orchestrate AtroCore, but don't modify its source) constitute a "combined work" with the GPL-3.0 code, or does GPL-3.0's "mere aggregation" carve-out apply to a Docker Compose setup that treats AtroCore as an installed application rather than a linked library?
2. Does `compliance_cmis`'s tracked `metadata/` overlay (entity definitions, layouts — recovered and tracked as of `atrocore-docker!` P2.6 this cycle) constitute a derivative work of the GPL-3.0 core, given it's data/config consumed by AtroCore's own extension mechanism rather than modified AtroCore source code?
3. Given `atrocore/atrocore-legacy`, `export`, `import`, `export-http`, `import-http` don't declare a license in their own `composer.json` (only in a bundled `LICENSE.txt`), is there any ambiguity about which license actually governs them, or does the bundled file control regardless?
4. If Workstream 5's "publish pre-built images" option is ever taken, what GPL-3.0 compliance is required at that point (offering corresponding source, written offer, etc.) — and does it change the calculus to *not* publish pre-built images and have adopters build from source instead (each adopter's own build never "distributes" anything to anyone else)?

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
