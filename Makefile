.PHONY: help up down bootstrap db-backup db-restore db-seed db-seed-demo db-seed-demo-remove db-seed-vocabularies db-seed-icao metadata-install metadata-export metadata-drift db-seed-nomenclatura install-layouts db-seed-starter db-seed-starter-remove import-data-packs validate-seeds validate-data-packs db-migrate db-migrate-status

help:
	@echo "Available targets:"
	@echo "  make up                        Start containers"
	@echo "  make down                      Stop containers"
	@echo "  make db-backup                 Create timestamped DB dump"
	@echo "  make db-restore DUMP=... [DB=...]"
	@echo "  make db-migrate-status         List pending schema migrations"
	@echo "  make db-migrate YES=1          Apply pending schema migrations"
	@echo "                                Restore dump into DB (destructive)"
	@echo "  make db-seed-vocabularies [DB=...] YES=1"
	@echo "                                Seed the USOAP/risk extensible enums (required)"
	@echo "  make db-seed-icao [DB=...] YES=1"
	@echo "                                Seed ICAO Annex documents/paragraphs/PQs (required)"
	@echo "  make db-seed-demo [DB=...] YES=1"
	@echo "                                Seed the synthetic demo dataset (additive, safe)"
	@echo "  make db-seed-demo-remove [DB=...] YES=1"
	@echo "                                Delete every demo- row"
	@echo "  make db-seed-starter [DB=...] YES=1"
	@echo "                                Seed the placeholder authority dataset (starter- rows,"
	@echo "                                editable; additive). Use instead of db-seed-demo."
	@echo "  make db-seed-starter-remove [DB=...] YES=1"
	@echo "                                Delete every starter- row"
	@echo "  make import-data-packs [PACK=...]"
	@echo "                                Import the authority data packs through AtroCore's own"
	@echo "                                import module (CSV templates under data-packs/; no PACK"
	@echo "                                means every pack). Editable equivalent of db-seed-starter."
	@echo "  make validate-seeds            Check the seed invariants (no Docker needed)"
	@echo "  make validate-data-packs       Check data-packs/ against the starter seed (no Docker)"
	@echo "  make db-seed [DUMP=atrocore.dump] [DB=...] YES=1"
	@echo "                                Restore a real pg_dump instead (destructive;"
	@echo "                                the dump is not in git — use db-seed-demo normally)"
	@echo "  make bootstrap                 Copy the AtroCore app out of the image into"
	@echo "                                web-data/ (first run on a clean clone; idempotent)"
	@echo "  make metadata-install          Install tracked metadata/ into web-data/"
	@echo "  make metadata-drift            Fail if metadata/ differs from the running instance"
	@echo "  make metadata-export           Copy the instance's metadata back into metadata/"
	@echo "                                (for an entity edited through the admin UI)"
	@echo "  make db-seed-nomenclatura [DB=...] YES=1"
	@echo "                                Seed Specialty/ActivityType/FindingSeverity catalogs"
	@echo "  make install-layouts YES=1"
	@echo "                                Seed the default layout profile's menu and materialise"
	@echo "                                metadata/layouts/ into it (needs the stack up)"
	@echo ""
	@echo "Quickstart order: up -> metadata-install -> db-seed-vocabularies -> db-seed-icao -> db-seed-nomenclatura -> install-layouts"
	@echo "  (all five are required; db-seed-demo is optional synthetic data, and install-layouts is"
	@echo "   what puts the platform's menu and layouts into the admin UI)"
	@echo "  (metadata-install bootstraps web-data/ itself when it is empty)"

up:
	docker compose up -d

down:
	docker compose down

bootstrap:
	./scripts/bootstrap-web-data.sh

db-backup:
	./scripts/backup-db.sh

db-restore:
	@if [ -z "$(DUMP)" ]; then \
		echo "Usage: make db-restore DUMP=db-dumps/your.dump [DB=target_db]"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/restore-db.sh "$(DUMP)" "$(DB)"; \
	else \
		./scripts/restore-db.sh "$(DUMP)"; \
	fi

db-migrate-status:
	./scripts/migrate-db.sh --status

# Run this BEFORE metadata-install: `sql diff` drops columns the new metadata no
# longer declares, so a migration that reads one has to get there first.
db-migrate:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-migrate YES=1"; \
		echo "Take a backup first (make db-backup)."; \
		exit 1; \
	fi
	./scripts/migrate-db.sh --yes

metadata-install:
	./scripts/install-metadata.sh

metadata-drift:
	./scripts/export-instance-metadata.py --check

metadata-export:
	./scripts/export-instance-metadata.py

install-layouts:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make install-layouts YES=1"; \
		exit 1; \
	fi
	./scripts/install-layouts.sh --yes

db-seed-nomenclatura:
	@if [ "$(YES)" != "1" ]; then \
		echo "Refusing destructive seed without YES=1"; \
		echo "Usage: make db-seed-nomenclatura [DB=target_db] YES=1"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-nomenclatura.sh "$(DB)" --yes; \
	else \
		./scripts/seed-nomenclatura.sh --yes; \
	fi

db-seed-vocabularies:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-vocabularies [DB=target_db] YES=1"; \
		echo "(additive: INSERT ... ON CONFLICT DO NOTHING, never overwrites)"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-usoap-vocabularies.sh "$(DB)" --yes; \
	else \
		./scripts/seed-usoap-vocabularies.sh --yes; \
	fi

db-seed-icao:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-icao [DB=target_db] YES=1"; \
		echo "(additive: INSERT ... ON CONFLICT DO NOTHING, never overwrites)"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-icao-reference-data.sh "$(DB)" --yes; \
	else \
		./scripts/seed-icao-reference-data.sh --yes; \
	fi

db-seed-demo:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-demo [DB=target_db] YES=1"; \
		echo "(additive seed: only rows with a demo- id are written)"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-demo-dataset.sh "$(DB)" --yes; \
	else \
		./scripts/seed-demo-dataset.sh --yes; \
	fi

db-seed-demo-remove:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-demo-remove [DB=target_db] YES=1"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-demo-dataset.sh "$(DB)" --remove --yes; \
	else \
		./scripts/seed-demo-dataset.sh --remove --yes; \
	fi

db-seed-starter:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-starter [DB=target_db] YES=1"; \
		echo "(additive: only rows with a starter- id are written; safe to re-run)"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-starter-dataset.sh "$(DB)" --yes; \
	else \
		./scripts/seed-starter-dataset.sh --yes; \
	fi

db-seed-starter-remove:
	@if [ "$(YES)" != "1" ]; then \
		echo "Usage: make db-seed-starter-remove [DB=target_db] YES=1"; \
		echo "(deletes every starter- row, including links an import created)"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-starter-dataset.sh "$(DB)" --remove --yes; \
	else \
		./scripts/seed-starter-dataset.sh --remove --yes; \
	fi

import-data-packs:
	@if [ -n "$(PACK)" ]; then \
		./scripts/import-data-pack.sh $(PACK); \
	else \
		./scripts/import-data-pack.sh --all; \
	fi

validate-seeds:
	python3 scripts/validate-seeds.py

validate-data-packs:
	python3 scripts/validate-data-packs.py

db-seed:
	@if [ "$(YES)" != "1" ]; then \
		echo "Refusing destructive seed without YES=1"; \
		echo "Usage: make db-seed [DUMP=atrocore.dump] [DB=target_db] YES=1"; \
		exit 1; \
	fi
	@if [ -n "$(DB)" ]; then \
		./scripts/seed-demo-db.sh "$(if $(DUMP),$(DUMP),atrocore.dump)" "$(DB)" --yes; \
	else \
		./scripts/seed-demo-db.sh "$(if $(DUMP),$(DUMP),atrocore.dump)" "" --yes; \
	fi
