--
-- Nomenclatura reference-catalog seed (AtroCore / AtroPIM)
--
-- Brings the controlled vocabularies in line with the client's new
-- abbreviation/code standard:
--
--   * public.specialty         -> flat catalog of 16 codes, no domain grouping
--   * public.activity_type     -> new 5-row oversight-activity-type catalog
--   * public.finding_severity  -> 3-row A/B/C catalog (7/30/90 days), read live
--                                 by compliance_web to derive finding deadlines
--
-- WHY A SCRIPT AND NOT A DUMP EDIT
-- --------------------------------
-- Specialty rows only ever existed inside the binary pg_dump files
-- (`atrocore.dump`, `db-dumps/*.dump`), which cannot be hand-edited. The
-- Postgres init hook (`.docker/postgres/scripts`, mounted at
-- /docker-entrypoint-initdb.d) is not usable either: it fires once, on first
-- initialisation of an empty PGDATA, at which point AtroCore has not yet
-- created any of its application tables. So this is an explicitly-invoked,
-- idempotent SQL script instead.
--
-- WHEN TO RUN
-- -----------
-- After the stack is up AND AtroCore has applied the schema implied by the JSON
-- metadata (see scripts/install-metadata.sh, then `console.php clear cache`
-- and `console.php sql diff --run`). That step is what creates/updates
-- `activity_type` and the new `activity_type_id` columns; this script only
-- fills in rows.
--
-- Note: this AtroCore build has no `rebuild` console command; `clear cache` +
-- `sql diff --run` is the equivalent.
--
-- HOW TO RUN
-- ----------
--   ./scripts/seed-nomenclatura.sh --yes            (preferred wrapper)
--   make db-seed-nomenclatura YES=1
--
-- Or directly:
--   docker compose exec -T db psql -U "$POSTGRES_PIM_USER" -d "$POSTGRES_PIM_DB" \
--     -v ON_ERROR_STOP=1 < sql/seed-nomenclatura-catalog.sql
--
-- DESTRUCTIVE: replaces every row in `specialty` and `activity_type`, and
-- clears the specialty grouping/hierarchy join rows. There is no production
-- data in this environment, so no migration or backfill is performed.
--
-- IDs are deterministic and human-readable (varchar(36)), so that sibling
-- repos can reference a stable catalog and re-running this script is a no-op
-- rather than a duplicate-insert. AtroCore accepts readable ids - see
-- 'defaultProfileId' in web-data/localhost/data/config.php.
--

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Safety net: create `activity_type` if the AtroCore schema sync has not run yet.
-- Shape mirrors public.finding_severity, this platform's existing pattern for
-- a small controlled vocabulary modelled as its own entity.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity_type (
    id character varying(36) NOT NULL,
    name character varying(255) DEFAULT NULL::character varying,
    deleted boolean DEFAULT false,
    description text,
    created_at timestamp(0) without time zone DEFAULT NULL::timestamp without time zone,
    modified_at timestamp(0) without time zone DEFAULT NULL::timestamp without time zone,
    created_by_id character varying(36) DEFAULT NULL::character varying,
    modified_by_id character varying(36) DEFAULT NULL::character varying,
    code character varying(255) DEFAULT NULL::character varying,
    sort_order integer
);

-- Add the primary key only if the table has none yet, so re-runs (and tables
-- already created by the AtroCore schema sync) do not error out.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.activity_type'::regclass
           AND contype  = 'p'
    ) THEN
        ALTER TABLE public.activity_type ADD PRIMARY KEY (id);
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- TASK A - flat Specialty catalog, grouping concept removed
-- ---------------------------------------------------------------------------

-- The Specialty <-> AssignmentGroup link and the Specialty self-hierarchy were
-- judged speculative by the client and are gone from the JSON metadata. Clear
-- the corresponding rows/values so nothing keeps scoping specialties by group.
--
-- Pure join tables are emptied outright rather than NULL-swept: a row in
-- inspector_specialty with a NULL specialty_id is meaningless junk. AtroCore
-- declares these links softly (the schema carries no FK constraints), so
-- nothing would otherwise stop the stale rows from surviving the reseed.
--
-- Each table is guarded, because a schema sync that has already picked up the new
-- metadata will have dropped specialty_hierarchy.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'specialty_hierarchy',
        'inspector_specialty',
        'location_service_specialty'
    ] LOOP
        IF to_regclass('public.' || t) IS NOT NULL THEN
            EXECUTE format('TRUNCATE TABLE public.%I', t);
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name   = 'specialty'
           AND column_name  = 'assignment_group_id'
    ) THEN
        UPDATE public.specialty SET assignment_group_id = NULL;
    END IF;
END
$$;

DELETE FROM public.specialty;

INSERT INTO public.specialty (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES
    ('spec_apr',  'Plataforma',                                        'APR',   10,  false, NOW(), NOW(), '1', '1'),
    ('spec_avis', 'Ayudas Visuales',                                   'AVIS',  20,  false, NOW(), NOW(), '1', '1'),
    ('spec_fau',  'Control de fauna',                                  'FAU',   30,  false, NOW(), NOW(), '1', '1'),
    ('spec_pav',  'Pavimento y características físicas',               'PAV',   40,  false, NOW(), NOW(), '1', '1'),
    ('spec_ssei', 'Servicio de salvamento y extinción de incendios',   'SSEI',  50,  false, NOW(), NOW(), '1', '1'),
    ('spec_aim',  'Gestión de información aeronáutica',                'AIM',   60,  false, NOW(), NOW(), '1', '1'),
    ('spec_ats',  'Servicio de tránsito aéreo',                        'ATS',   70,  false, NOW(), NOW(), '1', '1'),
    ('spec_com',  'Comunicaciones (voz)',                              'COM',   80,  false, NOW(), NOW(), '1', '1'),
    ('spec_ecns', 'Energía CNS',                                       'ECNS',  90,  false, NOW(), NOW(), '1', '1'),
    ('spec_emet', 'Equipos meteorológicos',                            'EMET',  100, false, NOW(), NOW(), '1', '1'),
    ('spec_fis',  'Servicio de información de vuelo',                  'FIS',   110, false, NOW(), NOW(), '1', '1'),
    ('spec_met',  'Meteorología aeronáutica',                          'MET',   120, false, NOW(), NOW(), '1', '1'),
    ('spec_nav',  'Navegación (radio ayudas)',                         'NAV',   130, false, NOW(), NOW(), '1', '1'),
    ('spec_sar',  'Búsqueda y salvamento',                             'SAR',   140, false, NOW(), NOW(), '1', '1'),
    ('spec_sur',  'Vigilancia (radar)',                                'SUR',   150, false, NOW(), NOW(), '1', '1'),
    ('spec_dpr',  'Procesamiento de datos (radar/ATN)',                'DPR',   160, false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- TASK B - ActivityType catalog (tipo de actividad de vigilancia)
--
-- The single-letter `code` is what the new document-ID scheme embeds into
-- generated ids in the sibling repos, so these codes are contract, not
-- cosmetic. Do not renumber or re-letter them without a cross-repo change.
-- ---------------------------------------------------------------------------
DELETE FROM public.activity_type;

INSERT INTO public.activity_type (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES
    ('atype_a', 'Auditoría',           'A', 10, false, NOW(), NOW(), '1', '1'),
    ('atype_i', 'Inspección',          'I', 20, false, NOW(), NOW(), '1', '1'),
    ('atype_m', 'Monitoreo',           'M', 30, false, NOW(), NOW(), '1', '1'),
    ('atype_d', 'Revisión documental', 'D', 40, false, NOW(), NOW(), '1', '1'),
    ('atype_s', 'Análisis de suceso',  'S', 50, false, NOW(), NOW(), '1', '1');

-- ---------------------------------------------------------------------------
-- TASK C - Inspection / InspectionCadence now link to ActivityType
--
-- `inspection_type` (free-text varchar) is replaced by `activity_type_id`.
-- The columns are created by the AtroCore schema sync; these guards keep the
-- script runnable in either order and drop the superseded free-text column.
-- ---------------------------------------------------------------------------
ALTER TABLE public.inspection        ADD COLUMN IF NOT EXISTS activity_type_id character varying(36) DEFAULT NULL::character varying;
ALTER TABLE public.inspection_cadence ADD COLUMN IF NOT EXISTS activity_type_id character varying(36) DEFAULT NULL::character varying;

-- Best-effort remap of the old free-text values before the column goes away.
-- Anything unrecognised simply ends up NULL; this is a dev catalog reset, not
-- a data migration.
--
-- Guarded on the column still existing: this script drops `inspection_type`
-- further down, so on any re-run there is nothing left to remap and the plain
-- UPDATE would abort with "column inspection_type does not exist".
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['inspection', 'inspection_cadence'] LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = t
               AND column_name  = 'inspection_type'
        ) THEN
            EXECUTE format($fmt$
                UPDATE public.%I
                   SET activity_type_id = CASE lower(btrim(coalesce(inspection_type, '')))
                        WHEN 'auditoria'   THEN 'atype_a'
                        WHEN 'auditoría'   THEN 'atype_a'
                        WHEN 'audit'       THEN 'atype_a'
                        WHEN 'inspection'  THEN 'atype_i'
                        WHEN 'inspeccion'  THEN 'atype_i'
                        WHEN 'inspección'  THEN 'atype_i'
                        WHEN 'monitoreo'   THEN 'atype_m'
                        WHEN 'monitoring'  THEN 'atype_m'
                        ELSE NULL
                   END
                 WHERE activity_type_id IS NULL
            $fmt$, t);
        END IF;
    END LOOP;
END
$$;

-- Default any cadence still without a type to "Inspección", matching the old
-- InspectionCadence.inspectionType default of "Inspection".
UPDATE public.inspection_cadence SET activity_type_id = 'atype_i' WHERE activity_type_id IS NULL;

ALTER TABLE public.inspection         DROP COLUMN IF EXISTS inspection_type;
ALTER TABLE public.inspection_cadence DROP COLUMN IF EXISTS inspection_type;

-- ---------------------------------------------------------------------------
-- Dangling specialty pointers
--
-- Several tables (inspection_cadence, inspected_specialty, protocol_question,
-- question_topic, ...) carry a soft `specialty_id`. Since the catalog ids all
-- changed, sweep every such column generically rather than hard-coding a list
-- that would silently rot as the model grows. Rows keep their identity; only
-- the stale pointer is cleared, for a human to re-link.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN
        SELECT c.table_name
          FROM information_schema.columns c
          JOIN information_schema.tables tb
            ON tb.table_schema = c.table_schema
           AND tb.table_name   = c.table_name
         WHERE c.table_schema = 'public'
           AND c.column_name  = 'specialty_id'
           AND tb.table_type  = 'BASE TABLE'
           AND c.table_name  <> 'specialty'
    LOOP
        EXECUTE format(
            'UPDATE public.%I SET specialty_id = NULL
              WHERE specialty_id IS NOT NULL
                AND specialty_id NOT IN (SELECT id FROM public.specialty)',
            t.table_name
        );
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- Finding-severity reference catalog (A/B/C)
--
-- compliance_web's server/findings/severityDeadlines.cjs queries this entity
-- live to derive a finding's submission and resolution deadlines, and throws
-- when there is no record for the severity.
--
-- The day counts are the authority's own, taken from the reference
-- Dominican-Republic deployment: A = 7 days to solution / 3 to submit,
-- B = 30 / 15, C = 90 / 30. days_to_solution also matches the field app's
-- configuration (compliance_checklist/app.config.json: 7/30/90), so the two
-- ends agree on the baseline.
--
-- Upsert, deliberately not delete-and-insert: unlike Specialty/ActivityType,
-- an administrator may have tuned these values, and re-running this script
-- must not wipe them.
-- ---------------------------------------------------------------------------
INSERT INTO public.finding_severity (
    id, name, description, days_to_solution, days_to_submission,
    deleted, created_at, modified_at, created_by_id, modified_by_id
)
VALUES
    ('severity_a', 'A', 'Severity A', 7,  3,  false, NOW(), NOW(), '1', '1'),
    ('severity_b', 'B', 'Severity B', 30, 15, false, NOW(), NOW(), '1', '1'),
    ('severity_c', 'C', 'Severity C', 90, 30, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO UPDATE
    SET name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        days_to_solution = EXCLUDED.days_to_solution,
        days_to_submission = EXCLUDED.days_to_submission,
        modified_at      = NOW();

COMMIT;

\echo 'Nomenclatura catalog seeded: 16 specialties, 5 activity types, 3 finding severities (A/B/C).'
