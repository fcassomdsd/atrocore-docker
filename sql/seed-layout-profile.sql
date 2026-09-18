--
-- Default layout-profile seed (AtroCore / AtroPIM)
--
-- WHY THIS EXISTS
-- ---------------
-- AtroCore loads *layout content* from the metadata files (installed by
-- install-metadata.sh), but which entities a user can reach at all is decided
-- by the `navigation` of the layout profile the user is assigned to. The stock
-- AtroCore installer seeds one profile (`default`, "Standard") whose navigation
-- is the AtroPIM menu — Product, File, Attribute, Classification, ImportFeed,
-- ExportFeed. None of this platform's entities are in it, so every platform
-- entity is invisible in the admin UI even though its layouts were installed.
--
-- (The layouts themselves are also inert as installed, because AtroCore reads
-- them from the `layout` database table / the core+module resource trees, not
-- from `data/layouts/`; scripts/install-layouts.sh materialises them into this
-- profile. This file only fixes the menu.)
--
-- WHAT IT WRITES
-- --------------
-- It updates the `default` profile in place rather than creating a second
-- profile: the core seeder already assigns every user to `default`, and
-- LayoutManager::getDefaultLayoutProfileId() looks up the single `is_default`
-- row. Groups reference entities by name; AtroCore drops any name whose scope
-- has no `tab` (LayotProfile service prepareEntityForOutput), so the list below
-- can safely name entities before they exist.
--
-- Deliberately NOT in the menu:
--   * Finding, CorrectiveAction, CorrectiveActionPlan, CorrectiveActionFollowUp
--     — these live in Alfresco; the AtroCore copies are unused.
--   * ActingInspector — disconnected (its links were removed).
--   * Tag — not enabled in the UI yet.
-- FindingSeverity *is* included: compliance_web reads it live for deadline maths.
-- InspectedProvider / InspectedService / InspectedSpecialty *are* included: they are
-- the per-provider inspection records the planning flow creates and the UI works with,
-- not Alfresco-stored and not unused.
--
-- IDEMPOTENT: INSERT ... ON CONFLICT (id) DO UPDATE. It intentionally does not
-- force `is_default` on an existing profile, so an administrator who promotes a
-- different profile keeps that choice.
--
-- HOW TO RUN
-- ----------
--   ./scripts/install-layouts.sh --yes     (applies this, then the layout content)
--   make install-layouts YES=1
--
-- Or directly, after the stack is up and the schema exists:
--   docker compose exec -T db psql -U "$POSTGRES_PIM_USER" -d "$POSTGRES_PIM_DB" \
--     -v ON_ERROR_STOP=1 < sql/seed-layout-profile.sql
--

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.layout_profile (
    id, name, description, is_active, is_default, deleted,
    navigation, dashboard_layout, favorites_list,
    created_at, modified_at, created_by_id, modified_by_id
)
VALUES (
    'default',
    'Standard',
    'Perfil por defecto de la plataforma: las entidades de vigilancia, sus catálogos y las herramientas de intercambio de datos.',
    true,
    true,
    false,
    $nav$[
  {"name": "vigilancia", "label": "Vigilancia", "items": ["SiteVisit", "Inspection", "InspectedProvider", "InspectedService", "InspectedSpecialty", "InspectionSchedule", "InspectionCadence", "ServiceArea", "AssignmentGroup"]},
  {"name": "entidades-reguladas", "label": "Entidades reguladas", "items": ["ServiceProvider", "Location", "LocationService", "Person"]},
  {"name": "recursos", "label": "Recursos", "items": ["Inspector"]},
  {"name": "cumplimiento", "label": "Cumplimiento (USOAP)", "items": ["Reglamento", "Normativa", "DocumentoOACI", "AcapiteOACI", "UsoapProtocolQuestion", "UsoapEvidenceExpectation"]},
  {"name": "catalogos", "label": "Catálogos", "items": ["Specialty", "ActivityType", "ChecklistQuestion", "InspectionQuestion", "QuestionTopic", "FindingSeverity"]},
  {"name": "intercambio", "label": "Intercambio de datos", "items": ["ExportFeed", "ImportFeed"]},
  {"name": "sistema", "label": "Sistema (AtroCore)", "items": ["Product", "File", "Attribute", "AttributePanel", "AttributeGroup", "Classification"]}
]$nav$,
    $dash$[{"name": "Vigilancia de la seguridad operacional", "layout": []}]$dash$,
    $fav$["SiteVisit", "Inspection", "Inspector", "FindingSeverity", "ImportFeed"]$fav$,
    NOW(), NOW(), '1', '1'
)
ON CONFLICT (id) DO UPDATE
    SET name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        is_active        = true,
        deleted          = false,
        navigation       = EXCLUDED.navigation,
        dashboard_layout = EXCLUDED.dashboard_layout,
        favorites_list   = EXCLUDED.favorites_list,
        modified_at      = NOW();

-- Re-assert only for users who have no profile at all; never override a choice.
UPDATE public."user"
   SET layout_profile_id = 'default'
 WHERE layout_profile_id IS NULL;

COMMIT;

\echo 'Default layout profile seeded: 26 platform entities in 7 groups (all 32 except the 6 deliberately omitted).'
