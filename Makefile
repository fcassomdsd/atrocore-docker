.PHONY: help up down db-backup db-restore db-seed metadata-install db-seed-nomenclatura

help:
	@echo "Available targets:"
	@echo "  make up                        Start containers"
	@echo "  make down                      Stop containers"
	@echo "  make db-backup                 Create timestamped DB dump"
	@echo "  make db-restore DUMP=... [DB=...]"
	@echo "                                Restore dump into DB (destructive)"
	@echo "  make db-seed [DUMP=atrocore.dump] [DB=...] YES=1"
	@echo "                                Seed DB with demo data (destructive)"
	@echo "  make metadata-install          Install tracked metadata/ into web-data/"
	@echo "  make db-seed-nomenclatura [DB=...] YES=1"
	@echo "                                Seed Specialty/ActivityType catalogs (destructive)"

up:
	docker compose up -d

down:
	docker compose down

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
