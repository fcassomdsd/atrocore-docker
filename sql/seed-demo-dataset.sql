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
-- one complete vertical slice of the platform — a site visit, two providers, two
-- inspections, three inspectors, their services and specialties, the interview
-- schedule the plan generator needs, and a checklist catalog (three topics, nine
-- questions) with its USOAP citation chain
-- (ChecklistQuestion -> Normativa -> AcapiteOACI -> UsoapProtocolQuestion).
--
-- It depends on sql/seed-usoap-vocabularies.sql for the risk-level and USOAP
-- extensible enums the questions and PQs point at.
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
-- A committed seed with hard-coded dates looks stale within a year, so both demo
-- site visits are dated relative to the day you seed: the one the closure
-- walkthrough uses is a month *behind* today and the one the planning walkthrough
-- uses is three weeks *ahead* of it (see section 7). The year embedded in the
-- Nomenclatura codes follows the current year, so the field workflow
-- (assign -> plan -> upload -> report) is always walkable and a closure is always
-- reviewed after the finding it closes. The stable identifiers to reference in
-- scripts and docs are the `id`s (`demo-sv-01`, `demo-insp-ans-01`, ...), not the
-- year-bearing codes.
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
-- 7. Site visits
--
-- Two visits, because the demo walks two halves of the lifecycle that cannot share a date:
--
--   demo-sv-01  in the *past*  — the ATS and MET inspections were carried out, their
--                                checklists and findings were imported, and a finding is
--                                walked through closure. Dating this visit in the future (as
--                                it used to be, `CURRENT_DATE + 21`) meant the demo reviewed
--                                a closure for an inspection that had not happened yet: the
--                                finding was issued *after* it was closed. Its window is the
--                                anchor the quickstart stamps the payload dates onto.
--   demo-sv-02  in the *future* — nothing has happened yet, so this is the visit the
--                                planning walkthrough uses: /inspectionPlan renders the plan
--                                and moves the inspection `Assigned` -> `Planned`.
--
-- Both are `V-XXXX-YYYY-##` per the platform Nomenclatura, with YYYY = the current year.
--
-- Seeded with statuses `/siteVisits` returns (Planned, Uploaded, Reported, Complete) on
-- purpose: a brand-new `Created` visit is deliberately hidden from the app's visit list, so a
-- seed that stopped at Created would look like an empty database.
-- ---------------------------------------------------------------------------
DELETE FROM public.site_visit WHERE id LIKE 'demo-%';

INSERT INTO public.site_visit (id, code, start_date, end_date, status, location_id, main_inspector_id, secondary_inspector_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-sv-01',
     'V-ZZZZ-' || to_char(CURRENT_DATE, 'YYYY') || '-01',
     CURRENT_DATE - 30,
     CURRENT_DATE - 29,
     'Complete',
     'demo-loc-zzzz', 'demo-insp-1', 'demo-insp-2',
     false, NOW(), NOW(), '1', '1'),
    ('demo-sv-02',
     'V-ZZZZ-' || to_char(CURRENT_DATE, 'YYYY') || '-02',
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
    ('demo-iprov-met', 'demo-prov-met', 'demo-sv-01', false, NOW(), NOW(), '1', '1'),
    ('demo-iprov-ans-02', 'demo-prov-ans', 'demo-sv-02', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 9. Inspections
--
-- One per inspected provider. `AV-XXXX-T-####` where T is the ActivityType
-- letter (A = Auditoría, I = Inspección); activity codes are sequenced
-- independently of the parent site visit's code.
--
-- The two past inspections are `Uploaded` (their checklists came in and their canonical
-- documents exist); the future one is `Assigned`, which is what /inspectionPlan moves to
-- `Planned` — seeding it as `Planned` would leave the plan walkthrough with no transition
-- to show.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspection WHERE id LIKE 'demo-%';

INSERT INTO public.inspection (id, code, objective, scope, location_id, inspected_provider_id, status, activity_type_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-insp-ans-01',
     'AV-ZZZZ-A-0001',
     'Verify compliance with the applicable air navigation service requirements.',
     'Air traffic services and radio navigation aids at Demo International Airport.',
     'demo-loc-zzzz', 'demo-iprov-ans', 'Uploaded', 'atype_a',
     false, NOW(), NOW(), '1', '1'),
    ('demo-insp-met-01',
     'AV-ZZZZ-I-0001',
     'Verify compliance with the applicable aeronautical meteorological service requirements.',
     'Aeronautical meteorological service and equipment at Demo International Airport.',
     'demo-loc-zzzz', 'demo-iprov-met', 'Uploaded', 'atype_i',
     false, NOW(), NOW(), '1', '1'),
    ('demo-insp-ans-02',
     'AV-ZZZZ-A-0002',
     'Verify compliance with the applicable air navigation service requirements.',
     'Air traffic services at Demo International Airport - planning walkthrough.',
     'demo-loc-zzzz', 'demo-iprov-ans-02', 'Assigned', 'atype_a',
     false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 10. Inspected services and their specialties
-- ---------------------------------------------------------------------------
DELETE FROM public.inspected_service WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_service (id, inspection_id, location_service_id, inspected_provider_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-isvc-ans-ats', 'demo-insp-ans-01', 'demo-lsvc-ans-ats', 'demo-iprov-ans', false, NOW(), NOW(), '1', '1'),
    ('demo-isvc-ans-nav', 'demo-insp-ans-01', 'demo-lsvc-ans-nav', 'demo-iprov-ans', false, NOW(), NOW(), '1', '1'),
    ('demo-isvc-met-met', 'demo-insp-met-01', 'demo-lsvc-met-met', 'demo-iprov-met', false, NOW(), NOW(), '1', '1'),
    ('demo-isvc-ans-02', 'demo-insp-ans-02', 'demo-lsvc-ans-ats', 'demo-iprov-ans-02', false, NOW(), NOW(), '1', '1');

DELETE FROM public.inspected_specialty WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_specialty (id, inspected_service_id, specialty_id, inspection_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-ispec-ans-ats', 'demo-isvc-ans-ats', 'spec_ats', 'demo-insp-ans-01', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-ans-nav', 'demo-isvc-ans-nav', 'spec_nav', 'demo-insp-ans-01', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-met-met', 'demo-isvc-met-met', 'spec_met', 'demo-insp-met-01', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-ans-02', 'demo-isvc-ans-02', 'spec_ats', 'demo-insp-ans-02', false, NOW(), NOW(), '1', '1');

DELETE FROM public.inspected_specialty_inspector WHERE id LIKE 'demo-%';

INSERT INTO public.inspected_specialty_inspector (id, inspected_specialty_id, inspector_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-ispec-insp-1', 'demo-ispec-ans-ats', 'demo-insp-1', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-insp-2', 'demo-ispec-ans-nav', 'demo-insp-2', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-insp-3', 'demo-ispec-met-met', 'demo-insp-3', false, NOW(), NOW(), '1', '1'),
    ('demo-ispec-insp-4', 'demo-ispec-ans-02', 'demo-insp-1', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 11. Interview / meeting schedule
--
-- The plan generator in compliance_flow looks up its opening and closing times
-- by schedule *name* and throws if either is missing, so every demo inspection
-- gets both ("Opening Meeting" / "Closing Meeting" are contract, not labels).
-- The ANS audit also gets a mid-visit interview to exercise the loop's
-- non-meeting branch.
--
-- Each schedule sits on its own inspection's visit dates: the past visit's on the past
-- window, the planning walkthrough's on the future one.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspection_schedule WHERE id LIKE 'demo-%';

INSERT INTO public.inspection_schedule (id, name, start_date_time, end_date_time, inspection_id, service_area_id, place, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-sched-ans-open',  'Opening Meeting', (CURRENT_DATE - 30) + TIME '09:00', (CURRENT_DATE - 30) + TIME '09:30', 'demo-insp-ans-01', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans-interview', 'Interview - air traffic services', (CURRENT_DATE - 30) + TIME '10:00', (CURRENT_DATE - 30) + TIME '12:00', 'demo-insp-ans-01', 'demo-area-ats', 'Demo International Airport - operations centre', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans-close', 'Closing Meeting', (CURRENT_DATE - 29) + TIME '15:00', (CURRENT_DATE - 29) + TIME '16:00', 'demo-insp-ans-01', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-met-open',  'Opening Meeting', (CURRENT_DATE - 30) + TIME '09:00', (CURRENT_DATE - 30) + TIME '09:30', 'demo-insp-met-01', 'demo-area-ats', 'Demo International Airport - meteorological office', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-met-close', 'Closing Meeting', (CURRENT_DATE - 29) + TIME '13:00', (CURRENT_DATE - 29) + TIME '14:00', 'demo-insp-met-01', 'demo-area-ats', 'Demo International Airport - meteorological office', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans02-open',  'Opening Meeting', (CURRENT_DATE + 21) + TIME '09:00', (CURRENT_DATE + 21) + TIME '09:30', 'demo-insp-ans-02', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1'),
    ('demo-sched-ans02-close', 'Closing Meeting', (CURRENT_DATE + 22) + TIME '15:00', (CURRENT_DATE + 22) + TIME '16:00', 'demo-insp-ans-02', 'demo-area-movement', 'Demo International Airport - conference room', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 12. Checklist catalog: topics and questions
--
-- Three topics with three questions each, one topic per demo specialty. Codes
-- follow the existing catalog's `<SPECIALTY>-<NNNN>` convention, `sequence`
-- orders them within a topic, and `risk_level` points at the risk-level
-- vocabulary seeded by sql/seed-usoap-vocabularies.sql. `references` is the
-- free-text "guidance" shown next to the normativa citation (see the flow's
-- "Convert to checklist format": `reference.normativa` comes from the chain
-- below, `reference.guidance` from this column).
--
-- `fecha_vigencia` is relative for the same reason the site visit is: a
-- committed catalog with fixed validity dates looks expired within a year.
-- ---------------------------------------------------------------------------
DELETE FROM public.question_topic WHERE id LIKE 'demo-%';

INSERT INTO public.question_topic (id, name, specialty_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-topic-ats', 'Air traffic services operations',      'spec_ats', false, NOW(), NOW(), '1', '1'),
    ('demo-topic-nav', 'Radio navigation aids',                'spec_nav', false, NOW(), NOW(), '1', '1'),
    ('demo-topic-met', 'Aeronautical meteorological service',  'spec_met', false, NOW(), NOW(), '1', '1');

DELETE FROM public.checklist_question WHERE id LIKE 'demo-%';

INSERT INTO public.checklist_question (id, texto, activo, fecha_vigencia, verification, specialty_id, topic_id, sequence, "references", code, risk_level, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-q-ats-01', 'Does the provider maintain a current operations manual that describes the air traffic services it provides, and is it available to the staff on duty?', true, CURRENT_DATE + 365, 'Verify that the manual is current, approved and available at the operational position.', 'spec_ats', 'demo-topic-ats', 10, 'Confirm the revision status and that the staff on duty know where to find it.', 'ATS-9001', 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-q-ats-02', 'Are shift handovers recorded, and do the records show that operational information is passed on completely?', true, CURRENT_DATE + 365, 'Sample the handover records for the last three months and confirm they are complete and signed.', 'spec_ats', 'demo-topic-ats', 20, 'Sample at least ten consecutive days.', 'ATS-9002', 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),
    ('demo-q-ats-03', 'Does the provider analyse its own safety occurrences and feed the conclusions back into its procedures?', true, CURRENT_DATE + 365, 'Review the occurrence register and the resulting changes to procedures.', 'spec_ats', 'demo-topic-ats', 30, 'Look for at least one closed occurrence with a documented procedural change.', 'ATS-9003', 'a01kny6p20qecjt1srcbvq1v99j', false, NOW(), NOW(), '1', '1'),

    ('demo-q-nav-01', 'Is the operational status of each radio navigation aid monitored continuously, and are outages notified to users without delay?', true, CURRENT_DATE + 365, 'Check the monitoring records and the notification log for the last six months.', 'spec_nav', 'demo-topic-nav', 10, 'Confirm the notification path to the users is documented.', 'NAV-9001', 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-q-nav-02', 'Are flight checks of the navigation aids carried out at the interval required by the provider''s maintenance programme?', true, CURRENT_DATE + 365, 'Verify that the last flight-check report is within the required interval and that any findings were closed.', 'spec_nav', 'demo-topic-nav', 20, 'The interval is defined in the maintenance programme, not in this checklist.', 'NAV-9002', 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-q-nav-03', 'Is the calibration and maintenance of navigation equipment performed by competent personnel with access to the required test equipment?', true, CURRENT_DATE + 365, 'Review the competence records and the calibration status of the test equipment.', 'spec_nav', 'demo-topic-nav', 30, 'Check that test equipment calibration certificates are in date.', 'NAV-9003', 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),

    ('demo-q-met-01', 'Does the provider issue the aeronautical meteorological reports and forecasts for which it is designated, within the required timeframes?', true, CURRENT_DATE + 365, 'Sample the issued reports against the designation list and the required times of issue.', 'spec_met', 'demo-topic-met', 10, 'Sample at least one full day of observations.', 'MET-9001', 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-q-met-02', 'Are the meteorological instruments calibrated at the required interval, and are the calibration records retained?', true, CURRENT_DATE + 365, 'Inspect the calibration register and verify that every instrument in operational use is in date.', 'spec_met', 'demo-topic-met', 20, 'Follow one instrument from the register to its physical location.', 'MET-9002', 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),
    ('demo-q-met-03', 'Are meteorological personnel trained and assessed on the equipment and procedures in operational use at this location?', true, CURRENT_DATE + 365, 'Review training records and the competency assessment for the personnel on the roster.', 'spec_met', 'demo-topic-met', 30, 'Confirm the roster matches the personnel assessed.', 'MET-9003', 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 13. USOAP citation chain
--
-- ChecklistQuestion -> Normativa -> AcapiteOACI -> UsoapProtocolQuestion, which
-- is exactly the chain compliance_flow's "getChecklistQuestion" walks: it
-- embeds `normativas` on each question, then resolves
-- AcapiteOACI.usoapProtocolQuestions and merges the PQ code / Critical Element /
-- area into `reference.normativa.usoapPqReference`.
--
-- Codes are deliberately synthetic. `UsoapProtocolQuestion.code` must satisfy
-- the entity's own pattern `/^PQ [0-9]{1,2}\.[0-9]{3}$/`, so these use the 99.x
-- range, which ICAO does not assign — the same "format-valid but obviously not
-- real" rule as the ZZZZ location. The ICAO Annex itself (Anexo 10 Volumen III)
-- is a public international standard, so citing it is fine; the national
-- regulation is the invented "Demo Civil Aviation Regulation".
-- ---------------------------------------------------------------------------
DELETE FROM public.documento_o_a_c_i WHERE id LIKE 'demo-%';
DELETE FROM public.acapite_o_a_c_i WHERE id LIKE 'demo-%';
DELETE FROM public.reglamento WHERE id LIKE 'demo-%';
DELETE FROM public.normativa WHERE id LIKE 'demo-%';
DELETE FROM public.usoap_protocol_question WHERE id LIKE 'demo-%';
DELETE FROM public.normativa_checklist_question WHERE id LIKE 'demo-%';
DELETE FROM public.usoap_protocol_question_acapite_o_a_c_i WHERE id LIKE 'demo-%';

INSERT INTO public.documento_o_a_c_i (id, name, codigo, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-doc-a10v3', 'Anexo 10 Volumen III', 'A10V3', false, NOW(), NOW(), '1', '1');

INSERT INTO public.acapite_o_a_c_i (id, name, documento_o_a_c_i_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-acapite-ats', 'A10 V3 3.1 (demo)', 'demo-doc-a10v3', false, NOW(), NOW(), '1', '1'),
    ('demo-acapite-nav', 'A10 V3 3.2 (demo)', 'demo-doc-a10v3', false, NOW(), NOW(), '1', '1'),
    ('demo-acapite-met', 'A10 V3 4.1 (demo)', 'demo-doc-a10v3', false, NOW(), NOW(), '1', '1');

INSERT INTO public.reglamento (id, name, codigo, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-reglamento-rad', 'Demo Civil Aviation Regulation', 'RAD-DEMO', false, NOW(), NOW(), '1', '1');

INSERT INTO public.normativa (id, name, texto, activo, fecha_vigencia, reglamento_id, acapites_o_a_c_i_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-norm-ats', 'Article 10.11 (demo)',
     'The air navigation service provider shall maintain an operations manual describing the services provided and the procedures to be followed by operational personnel, and shall keep it available at each operational position.',
     true, CURRENT_DATE + 365, 'demo-reglamento-rad', 'demo-acapite-ats', false, NOW(), NOW(), '1', '1'),
    ('demo-norm-nav', 'Article 10.12 (demo)',
     'The air navigation service provider shall monitor the operational status of radio navigation aids, notify users without delay of any interruption of service, and carry out periodic flight checks in accordance with its maintenance programme.',
     true, CURRENT_DATE + 365, 'demo-reglamento-rad', 'demo-acapite-nav', false, NOW(), NOW(), '1', '1'),
    ('demo-norm-met', 'Article 11.4 (demo)',
     'The meteorological service provider shall issue the aeronautical meteorological reports and forecasts for which it has been designated within the required timeframes, and shall ensure that its instruments and personnel remain competent for the service provided.',
     true, CURRENT_DATE + 365, 'demo-reglamento-rad', 'demo-acapite-met', false, NOW(), NOW(), '1', '1');

INSERT INTO public.normativa_checklist_question (id, normativa_id, checklist_question_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-link-ats-01', 'demo-norm-ats', 'demo-q-ats-01', false, NOW(), NOW(), '1', '1'),
    ('demo-link-ats-02', 'demo-norm-ats', 'demo-q-ats-02', false, NOW(), NOW(), '1', '1'),
    ('demo-link-ats-03', 'demo-norm-ats', 'demo-q-ats-03', false, NOW(), NOW(), '1', '1'),
    ('demo-link-nav-01', 'demo-norm-nav', 'demo-q-nav-01', false, NOW(), NOW(), '1', '1'),
    ('demo-link-nav-02', 'demo-norm-nav', 'demo-q-nav-02', false, NOW(), NOW(), '1', '1'),
    ('demo-link-nav-03', 'demo-norm-nav', 'demo-q-nav-03', false, NOW(), NOW(), '1', '1'),
    ('demo-link-met-01', 'demo-norm-met', 'demo-q-met-01', false, NOW(), NOW(), '1', '1'),
    ('demo-link-met-02', 'demo-norm-met', 'demo-q-met-02', false, NOW(), NOW(), '1', '1'),
    ('demo-link-met-03', 'demo-norm-met', 'demo-q-met-03', false, NOW(), NOW(), '1', '1');

INSERT INTO public.usoap_protocol_question (id, code, texto, critical_element, area_code, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-pq-ats', 'PQ 99.001',
     'Has the State established and implemented procedures to ensure that air navigation service providers maintain operations manuals and record shift handovers?',
     'a01m00yj3d9e9fb7j59wynx6239', '["a01m00yjbqpeett9fgd5pjz2c63"]', false, NOW(), NOW(), '1', '1'),
    ('demo-pq-nav', 'PQ 99.002',
     'Has the State established and implemented procedures to ensure that radio navigation aids are monitored, that interruptions are notified, and that flight checks are carried out?',
     'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjc10ea3vyn35gvx1ta0g"]', false, NOW(), NOW(), '1', '1'),
    ('demo-pq-met', 'PQ 99.003',
     'Has the State established and implemented procedures to ensure that designated aeronautical meteorological services are provided within the required timeframes by competent personnel and calibrated equipment?',
     'a01m00yj2eye3xrkgj0e4yy3400', '["a01m00yjd6be3rbx3y13yjhxhes"]', false, NOW(), NOW(), '1', '1');

INSERT INTO public.usoap_protocol_question_acapite_o_a_c_i (id, acapite_o_a_c_i_id, usoap_protocol_question_id, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-pq-acapite-ats', 'demo-acapite-ats', 'demo-pq-ats', false, NOW(), NOW(), '1', '1'),
    ('demo-pq-acapite-nav', 'demo-acapite-nav', 'demo-pq-nav', false, NOW(), NOW(), '1', '1'),
    ('demo-pq-acapite-met', 'demo-acapite-met', 'demo-pq-met', false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- 14. Per-inspection checklist selections
--
-- /checklist does NOT read the master catalog: the flow resolves
-- Specialty(code) -> InspectedSpecialty(inspectionId, specialtyId) and then
-- queries InspectionQuestion by inspectedSpecialtyId, embedding the catalog
-- question through checklist_question_id. So the catalog above is invisible to
-- the app until an inspection selects it — this is the "Checklist Manager"
-- step, seeded here so the demo inspection has a checklist to fill in.
--
-- `compliance` and `comments` are left empty on purpose: nothing has been
-- executed yet, which is the state a fresh inspection should be in.
-- ---------------------------------------------------------------------------
DELETE FROM public.inspection_question WHERE id LIKE 'demo-%';

INSERT INTO public.inspection_question (id, inspected_specialty_id, checklist_question_id, code, sequence, risk_level, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('demo-iq-ats-01', 'demo-ispec-ans-ats', 'demo-q-ats-01', 'ATS-9001', 10, 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-ats-02', 'demo-ispec-ans-ats', 'demo-q-ats-02', 'ATS-9002', 20, 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-ats-03', 'demo-ispec-ans-ats', 'demo-q-ats-03', 'ATS-9003', 30, 'a01kny6p20qecjt1srcbvq1v99j', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-nav-01', 'demo-ispec-ans-nav', 'demo-q-nav-01', 'NAV-9001', 10, 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-nav-02', 'demo-ispec-ans-nav', 'demo-q-nav-02', 'NAV-9002', 20, 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-nav-03', 'demo-ispec-ans-nav', 'demo-q-nav-03', 'NAV-9003', 30, 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-met-01', 'demo-ispec-met-met', 'demo-q-met-01', 'MET-9001', 10, 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-met-02', 'demo-ispec-met-met', 'demo-q-met-02', 'MET-9002', 20, 'a01kny6my3bebmsk16tftcpgqgy', false, NOW(), NOW(), '1', '1'),
    ('demo-iq-met-03', 'demo-ispec-met-met', 'demo-q-met-03', 'MET-9003', 30, 'a01kny6nptsedzrrvt4yh1wwkz8', false, NOW(), NOW(), '1', '1');

COMMIT;
