.PHONY: help up down bootstrap db-backup db-restore db-seed db-seed-demo db-seed-demo-remove db-seed-vocabularies metadata-install metadata-export metadata-drift db-seed-nomenclatura

help:
	@echo "Available targets:"
	@echo "  make up                        Start containers"
	@echo "  make down                      Stop containers"
	@echo "  make db-backup                 Create timestamped DB dump"
	@echo "  make db-restore DUMP=... [DB=...]"
	@echo "                                Restore dump into DB (destructive)"
	@echo "  make db-seed-vocabularies [DB=...] YES=1"
	@echo "                                Seed the USOAP/risk extensible enums (required)"
	@echo "  make db-seed-demo [DB=...] YES=1"
	@echo "                                Seed the synthetic demo dataset (additive, safe)"
	@echo "  make db-seed-demo-remove [DB=...] YES=1"
	@echo "                                Delete every demo- row"
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
	@echo "                                Seed Specialty/ActivityType catalogs (destructive)"
	@echo ""
	@echo "Quickstart order: up -> metadata-install -> db-seed-vocabularies -> db-seed-nomenclatura -> db-seed-demo"
	@echo "(metadata-install bootstraps web-data/ itself when it is empty)"

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

metadata-install:
	./scripts/install-metadata.sh

metadata-drift:
	./scripts/export-instance-metadata.py --check

metadata-export:
	./scripts/export-instance-metadata.py

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
