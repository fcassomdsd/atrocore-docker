--
-- Starter authority dataset (AtroCore / AtroPIM) — PLACEHOLDERS TO EDIT
--
-- WHAT THIS IS
-- ------------
-- A minimal, coherent set of the authority-specific records a new deployment needs
-- before it can plan an inspection, so an adopter can see how the entities relate
-- and then replace the values with their own. It is NOT the demo dataset: the demo
-- (`sql/seed-demo-dataset.sql`) is synthetic ZZZZ/`demo-` data used by the
-- quickstart, and the two are meant to be used instead of each other, not together.
--
-- Everything here is namespaced `starter-` and every display name says "(editar)".
-- It is additive and idempotent (`ON CONFLICT (id) DO NOTHING`), so re-running it
-- never overwrites a value you have edited, and it never touches a non-`starter-`
-- row. Remove it with `scripts/seed-starter-dataset.sh --remove --yes` once you have
-- entered your real data.
--
-- WHAT IS DELIBERATELY ABSENT
-- ---------------------------
--   * Specialty, ActivityType, FindingSeverity and the USOAP vocabularies — those are
--     real reference catalogs, not authority data; they are seeded by
--     seed-nomenclatura.sh / seed-usoap-vocabularies.sh.
--   * SiteVisit / Inspection / InspectedProvider* / InspectionCadence — used per-visit
--     operational records that the planning flow creates and the navigation exposes, not
--     seeded (a cadence requires an InspectedProvider, which only exists after a site visit
--     has been planned).
--   * Finding / CorrectiveAction* — those live in Alfresco.
--   * Tag — not enabled in the UI yet.
--
-- The USOAP citation chain (UsoapProtocolQuestion -> AcapiteOACI -> Normativa ->
-- ChecklistQuestion) is already seeded from ICAO with `seed-icao-reference-data.sh`.
-- The starter Normativa rows below therefore leave `acapites_o_a_c_i_id` NULL: link
-- them to the real Annex paragraphs once you enter your national regulation.
--
-- HOW TO RUN
-- ----------
--   ./scripts/seed-starter-dataset.sh --yes
--   make db-seed-starter YES=1
--
-- Prerequisites: stack up, metadata installed, `sql diff --run` applied (the tables
-- must exist).

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------- reference rows
INSERT INTO public.service_area (id, name, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-area-general', 'Servicios generales (editar)', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.service_provider (id, name, alias, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-prov-01', 'Proveedor de servicios de ejemplo (editar)', 'EJEMPLO', 10, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.location (id, name, city, province, icao_code, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-loc-01', 'Aeropuerto de ejemplo (editar)', 'Ciudad (editar)', 'Provincia (editar)', 'XXXX', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.person (id, name, service_provider_id, work_i_d, work_position, work_email, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-poc-01', 'Persona de contacto de ejemplo (editar)', 'starter-prov-01', 'EJEMPLO-0001', 'Puesto (editar)', 'contacto@ejemplo.invalid', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.assignment_group (id, name, description, external_group, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-group-01', 'Grupo de asignación de ejemplo (editar)', 'Grupo que agrupa inspectores para la asignación (editar)', 'GRP-EJEMPLO', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------------- inspectors
INSERT INTO public.inspector (id, name, organization_i_d, external_user_i_d, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-insp-01', 'Inspector de ejemplo (editar)', 'CAA', 'inspector.ejemplo', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- Specialty codes are the real, seeded catalog (spec_ats = ATS, etc.).
INSERT INTO public.inspector_specialty (id, inspector_id, specialty_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-insp-01-ats', 'starter-insp-01', 'spec_ats', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- --------------------------------------------------------- location ↔ provider
INSERT INTO public.location_service (id, name, short_name, location_id, service_provider_id, point_of_contact_id, service_area_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-lsvc-01', 'Servicio de ejemplo en el aeropuerto de ejemplo (editar)', 'EJ', 'starter-loc-01', 'starter-prov-01', 'starter-poc-01', 'starter-area-general', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------------ regulation
INSERT INTO public.reglamento (id, name, codigo, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-reglamento-01', 'Reglamento de aviación civil de ejemplo (editar)', 'RAD-XXXX', false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- `acapites_o_a_c_i_id` is left NULL on purpose: link each article to the real ICAO
-- Annex paragraph (seeded by seed-icao-reference-data.sh) when you enter your regulation.
INSERT INTO public.normativa (id, name, texto, activo, fecha_vigencia, reglamento_id, acapites_o_a_c_i_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('starter-norm-01', 'Artículo de ejemplo 1 (editar)',
     'El proveedor de servicios de navegación aérea debe mantener un manual de operaciones que describa los servicios prestados y los procedimientos que debe seguir el personal operativo, y debe mantenerlo disponible en cada puesto operativo. (Texto de ejemplo: sustituir por el artículo real.)',
     true, DATE '2027-12-31', 'starter-reglamento-01', NULL, false, NOW(), NOW(), '1', '1'),
    ('starter-norm-02', 'Artículo de ejemplo 2 (editar)',
     'El proveedor de servicios de navegación aérea debe vigilar el estado operativo de las ayudas a la navegación radioeléctrica, notificar sin demora a los usuarios cualquier interrupción del servicio y realizar comprobaciones periódicas en vuelo conforme a su programa de mantenimiento. (Texto de ejemplo: sustituir por el artículo real.)',
     true, DATE '2027-12-31', 'starter-reglamento-01', NULL, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------ inspection cadence
-- Deliberately not seeded: `InspectionCadence.inspectedProvider` is a required link to
-- `InspectedProvider`, which is an operational, per-site-visit record (it belongs to a
-- `SiteVisit` and a `ServiceProvider`), not authority data. A fresh install has no
-- `InspectedProvider`, so any cadence row here would be a dangling link that the UI cannot
-- save and the import module rejects ("no record(s) found in the entity 'InspectedProvider'").
-- Create cadences in the UI once a site visit has been planned; `data-packs/README.md`
-- describes how to bulk-load them afterwards.

COMMIT;

\echo 'Starter authority dataset seeded (11 placeholder rows across 10 tables). Edit the values or remove with --remove.'
