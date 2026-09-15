--
-- Demo dataset seed (AtroCore / AtroPIM)
--
-- PURPOSE
-- -------
-- A fresh install of this platform is structurally complete and completely
-- empty: the metadata, the reference catalogs and the Web Scripts are all
-- version-controlled, but every operational record (locations, providers,
-- inspectors, site visits, inspections) has only ever lived inside the binary
-- pg_dump files (`atrocore.dump`, `db-dumps/*.dump`). Those are gitignored and
-- were purged from history in the P0 secret cleanup, so `git clone` + `docker
-- compose up` gives an app with nothing to show and nothing to click.
--
-- This script fills that gap with a small, wholly synthetic dataset: enough for
-- one complete vertical slice of the platform (a site visit, two providers, two
-- inspections, three inspectors, their services and specialties, and the
-- interview schedule the plan generator needs).
--
-- WHY A SCRIPT AND NOT A DUMP
-- ---------------------------
-- Same reason as sql/seed-nomenclatura-catalog.sql: a dump cannot be reviewed,
-- cannot be hand-edited, breaks on every metadata change, and — the reason the
-- old dumps were purged — smuggles credentials and real records into git. This
-- file is readable in a diff, contains no secrets, and re-runs cleanly.
--
-- SYNTHETIC BY CONSTRUCTION
-- -------------------------
-- Everything here is fictional and must stay that way:
--   * every `id` starts with `demo-`, so the whole dataset can be removed with
--     `scripts/seed-demo-dataset.sh --remove` without touching anything else;
--   * the location's ICAO code is `ZZZZ`, ICAO's own "unknown aerodrome"
--     placeholder, so generated document codes (`V-ZZZZ-2026-01`,
--     `AV-ZZZZ-A-0001`) are obviously not a real State's records;
--   * e-mail addresses use the reserved `.invalid` TLD;
--   * names are invented (`Demo Air Navigation Services`, `Alex Demo`).
-- Never put a real authority's data in this file. See the P0 finding in
-- TECHNICAL_DEBT_ANALYSIS.md.
--
-- ADDITIVE, NOT DESTRUCTIVE
-- -------------------------
-- Unlike the two catalog seeds, this one is safe to run against a database that
-- already holds real records: it deletes and re-inserts **only rows whose id
-- starts with `demo-`**, and never truncates a table. AtroCore declares no
-- database-level foreign keys (relations are managed in the application), so
-- the order below is for readability, not for constraint satisfaction.
--
-- ATOMIC AND RE-RUNNABLE. The whole file runs in one transaction.
--
-- WHEN TO RUN
-- -----------
-- After the stack is up and AtroCore has applied the schema implied by the JSON
-- metadata:
--
--   docker compose up -d
--   ./scripts/install-metadata.sh
--   docker compose exec atro-web php /var/www/localhost/console.php clear cache
--   docker compose exec atro-web php /var/www/localhost/console.php sql diff --run
--   ./scripts/seed-demo-dataset.sh --yes
--
-- It depends on the Specialty and ActivityType catalogs from
-- seed-nomenclatura-catalog.sql (`spec_ats`, `spec_nav`, `spec_met`, `atype_a`,
-- `atype_i`), so run that first.
--
-- DATES ARE RELATIVE ON PURPOSE
-- -----------------------------
-- A committed seed with hard-coded dates looks stale within a year. The demo
-- site visit is therefore always three weeks ahead of the day you seed, and the
-- year embedded in the Nomenclatura codes follows the current year, so the
-- field workflow (assign -> plan -> upload -> report) is always walkable. The
-- stable identifiers to reference in scripts and docs are the `id`s
-- (`demo-sv-01`, `demo-insp-ans-01`, ...), not the year-bearing codes.
--

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Reference data: service areas
-- ---------------------------------------------------------------------------
DELETE FROM public.service_area WHERE id LIKE 'demo-%';

INSERT INTO public.service_area (id, name, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-area-movement', 'Aircraft movement area', false, NOW(), NOW(), '1', '1'),
    ('demo-area-ats',      'Air traffic services',  false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 2. Service providers
-- ---------------------------------------------------------------------------
DELETE FROM public.service_provider WHERE id LIKE 'demo-%';

INSERT INTO public.service_provider (id, name, alias, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-prov-ans', 'Demo Air Navigation Services', 'DANS', 10, false, NOW(), NOW(), '1', '1'),
    ('demo-prov-met', 'Demo Meteorological Services', 'DMS',  20, false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 3. Location
--
-- `ZZZZ` is ICAO's "unknown aerodrome" placeholder: format-valid for the
-- Nomenclatura document codes, and unmistakably not a real airport.
-- ---------------------------------------------------------------------------
DELETE FROM public.location WHERE id LIKE 'demo-%';

INSERT INTO public.location (id, name, city, province, icao_code, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-loc-zzzz', 'Demo International Airport', 'Demo City', 'Demo Province', 'ZZZZ', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 4. Provider points of contact
--
-- `work_email` uses the reserved `.invalid` TLD so nothing here can ever be
-- delivered to a real mailbox.
-- ---------------------------------------------------------------------------
DELETE FROM public.person WHERE id LIKE 'demo-%';

INSERT INTO public.person (id, name, service_provider_id, work_i_d, work_position, work_email, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-poc-ans', 'Dana Demo',  'demo-prov-ans', 'DANS-0001', 'Operations Manager',      'ops@demo-ans.invalid',   false, NOW(), NOW(), '1', '1'),
    ('demo-poc-met', 'Morgan Demo', 'demo-prov-met', 'DMS-0001',  'Chief Meteorologist',     'chief@demo-met.invalid', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 5. Inspectors
--
-- `external_user_i_d` is the identity the checklist app matches the logged-in
-- operator against. These are *records*, not login accounts: no Alfresco user
-- is created here, so a demo deployment that wants to log in as one of them
-- still has to create the Alfresco user and its group membership.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspector WHERE id LIKE 'demo-%';

INSERT INTO public.inspector (id, name, organization_i_d, external_user_i_d, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-insp-1', 'Alex Demo',    'DEMO-CAA', 'demo.inspector1', false, NOW(), NOW(), '1', '1'),
    ('demo-insp-2', 'Bailey Demo',  'DEMO-CAA', 'demo.inspector2', false, NOW(), NOW(), '1', '1'),
    ('demo-insp-3', 'Casey Demo',   'DEMO-CAA', 'demo.inspector3', false, NOW(), NOW(), '1', '1');

DELETE FROM public.inspector_specialty WHERE id LIKE 'demo-%';

INSERT INTO public.inspector_specialty (id, inspector_id, specialty_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-insp-1-ats', 'demo-insp-1', 'spec_ats', false, NOW(), NOW(), '1', '1'),
    ('demo-insp-2-nav', 'demo-insp-2', 'spec_nav', false, NOW(), NOW(), '1', '1'),
    ('demo-insp-3-met', 'demo-insp-3', 'spec_met', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 6. Services provided at the location
--
-- One `location_service` per (provider, specialty) pair that will be inspected.
-- ---------------------------------------------------------------------------
DELETE FROM public.location_service WHERE id LIKE 'demo-%';

INSERT INTO public.location_service (id, name, short_name, location_id, service_provider_id, point_of_contact_id, service_area_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-lsvc-ans-ats', 'Demo ANS - Air traffic services', 'ATS', 'demo-loc-zzzz', 'demo-prov-ans', 'demo-poc-ans', 'demo-area-ats',      false, NOW(), NOW(), '1', '1'),
    ('demo-lsvc-ans-nav', 'Demo ANS - Radio navigation',     'NAV', 'demo-loc-zzzz', 'demo-prov-ans', 'demo-poc-ans', 'demo-area-movement', false, NOW(), NOW(), '1', '1'),
    ('demo-lsvc-met-met', 'Demo MET - Aeronautical meteorology', 'MET', 'demo-loc-zzzz', 'demo-prov-met', 'demo-poc-met', 'demo-area-ats',  false, NOW(), NOW(), '1', '1');

DELETE FROM public.location_service_specialty WHERE id LIKE 'demo-%';

INSERT INTO public.location_service_specialty (id, location_service_id, specialty_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-lsvc-ans-ats-ats', 'demo-lsvc-ans-ats', 'spec_ats', false, NOW(), NOW(), '1', '1'),
    ('demo-lsvc-ans-nav-nav', 'demo-lsvc-ans-nav', 'spec_nav', false, NOW(), NOW(), '1', '1'),
    ('demo-lsvc-met-met-met', 'demo-lsvc-met-met', 'spec_met', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 7. Site visit
--
-- Always three weeks out, so the assign -> plan -> upload -> report workflow is
-- walkable whenever the dataset is seeded. `V-XXXX-YYYY-##` per the platform
-- Nomenclatura, with YYYY = the current year.
--
-- Seeded as `Planned`, not `Created`, on purpose: /siteVisits only returns
-- visits whose status is Planned, Uploaded, Reported or Complete (a brand-new
-- Created visit is deliberately hidden from the app's visit list), so a seed
-- that stopped at Created would look like an empty database. `Planned` is also
-- where the demo's first action belongs — generating the inspection plan, which
-- then moves the inspection to Uploaded through /importCanonical.
-- ---------------------------------------------------------------------------
DELETE FROM public.site_visit WHERE id LIKE 'demo-%';

INSERT INTO public.site_visit (id, code, start_date, end_date, status, location_id, main_inspector_id, secondary_inspector_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-sv-01',
     'V-ZZZZ-' || to_char(CURRENT_DATE, 'YYYY') || '-01',
     CURRENT_DATE + 21,
     CURRENT_DATE + 22,
     'Planned',
     'demo-loc-zzzz', 'demo-insp-1', 'demo-insp-2',
     false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 8. Inspected providers (one per provider present at the site visit)
-- ---------------------------------------------------------------------------
DELETE FROM public.inspected_provider WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_provider (id, service_provider_id, site_visit_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-iprov-ans', 'demo-prov-ans', 'demo-sv-01', false, NOW(), NOW(), '1', '1'),
    ('demo-iprov-met', 'demo-prov-met', 'demo-sv-01', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 9. Inspections
--
-- One per inspected provider. `AV-XXXX-T-####` where T is the ActivityType
-- letter (A = Auditoría, I = Inspección); activity codes are sequenced
-- independently of the parent site visit's code.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspection WHERE id LIKE 'demo-%';

INSERT INTO public.inspection (id, code, objective, scope, location_id, inspected_provider_id, status, activity_type_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-insp-ans-01',
     'AV-ZZZZ-A-0001',
     'Verify compliance with the applicable air navigation service requirements.',
     'Air traffic services and radio navigation aids at Demo International Airport.',
     'demo-loc-zzzz', 'demo-iprov-ans', 'Planned', 'atype_a',
     false, NOW(), NOW(), '1', '1'),
    ('demo-insp-met-01',
     'AV-ZZZZ-I-0001',
     'Verify compliance with the applicable aeronautical meteorological service requirements.',
     'Aeronautical meteorological service and equipment at Demo International Airport.',
     'demo-loc-zzzz', 'demo-iprov-met', 'Planned', 'atype_i',
     false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 10. Inspected services and their specialties
-- ---------------------------------------------------------------------------
DELETE FROM public.inspected_service WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_service (id, inspection_id, location_service_id, inspected_provider_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-isvc-ans-ats', 'demo-insp-ans-01', 'demo-lsvc-ans-ats', 'demo-iprov-ans', false, NOW(), NOW(), '1', '1'),
    ('demo-isvc-ans-nav', 'demo-insp-ans-01', 'demo-lsvc-ans-nav', 'demo-iprov-ans', false, NOW(), NOW(), '1', '1'),
    ('demo-isvc-met-met', 'demo-insp-met-01', 'demo-lsvc-met-met', 'demo-iprov-met', false, NOW(), NOW(), '1', '1');

DELETE FROM public.inspected_specialty WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_specialty (id, inspected_service_id, specialty_id, inspection_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-ispec-ans-ats', 'demo-isvc-ans-ats', 'spec_ats', 'demo-insp-ans-01', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-ans-nav', 'demo-isvc-ans-nav', 'spec_nav', 'demo-insp-ans-01', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-met-met', 'demo-isvc-met-met', 'spec_met', 'demo-insp-met-01', false, NOW(), NOW(), '1', '1');

DELETE FROM public.inspected_specialty_inspector WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_specialty_inspector (id, inspected_specialty_id, inspector_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-ispec-insp-1', 'demo-ispec-ans-ats', 'demo-insp-1', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-insp-2', 'demo-ispec-ans-nav', 'demo-insp-2', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-insp-3', 'demo-ispec-met-met', 'demo-insp-3', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 11. Interview / meeting schedule
--
-- The plan generator in compliance_flow looks up its opening and closing times
-- by schedule *name* and throws if either is missing, so every demo inspection
-- gets both ("Opening Meeting" / "Closing Meeting" are contract, not labels).
-- The ANS audit also gets a mid-visit interview to exercise the loop's
-- non-meeting branch.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspection_schedule WHERE id LIKE 'demo-%';

INSERT INTO public.inspection_schedule (id, name, start_date_time, end_date_time, inspection_id, service_area_id, place, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-sched-ans-open',  'Opening Meeting', (CURRENT_DATE + 21) + TIME '09:00', (CURRENT_DATE + 21) + TIME '09:30', 'demo-insp-ans-01', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans-interview', 'Interview - air traffic services', (CURRENT_DATE + 21) + TIME '10:00', (CURRENT_DATE + 21) + TIME '12:00', 'demo-insp-ans-01', 'demo-area-ats', 'Demo International Airport - operations centre', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans-close', 'Closing Meeting', (CURRENT_DATE + 22) + TIME '15:00', (CURRENT_DATE + 22) + TIME '16:00', 'demo-insp-ans-01', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-met-open',  'Opening Meeting', (CURRENT_DATE + 21) + TIME '09:00', (CURRENT_DATE + 21) + TIME '09:30', 'demo-insp-met-01', 'demo-area-ats', 'Demo International Airport - meteorological office', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-met-close', 'Closing Meeting', (CURRENT_DATE + 22) + TIME '13:00', (CURRENT_DATE + 22) + TIME '14:00', 'demo-insp-met-01', 'demo-area-ats', 'Demo International Airport - meteorological office', false, NOW(), NOW(), '1', '1');

COMMIT;
