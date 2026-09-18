--
-- Spanish (es_DO) labels for the controlled vocabularies — reference data, not authority data.
--
-- AtroCore stores a multilingual field's translations in sibling columns (name_es_do for a
-- field named `name`), and only creates those columns once `es_DO` is configured as an
-- additional language (see scripts/enable-spanish-labels.sh). The values here are the ones
-- the reference Dominican-Republic deployment used, so its screens read the same.
--
-- Only the three vocabularies the DR instance actually translated are covered. The rest
-- (riskLevel, usoapAreaCode, usoapArtifactCategory, usoapCriticalElement) were left blank
-- there too — their codes are the display (CE-1, ATS, …).
--
-- Idempotent: plain UPDATEs keyed on (enum code, option code). It never inserts rows.
--
-- HOW TO RUN
--   ./scripts/enable-spanish-labels.sh --yes    (configures the language, syncs the schema, then runs this)
--   or directly, once the column exists:
--     docker compose exec -T db psql -U "$POSTGRES_PIM_USER" -d "$POSTGRES_PIM_DB" \
--       -v ON_ERROR_STOP=1 < sql/seed-vocabulary-translations.sql
--

\set ON_ERROR_STOP on

-- Fail loudly rather than silently doing nothing when the language is not configured yet:
-- without the column the app would keep showing the English names and the cause would be
-- invisible.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name   = 'extensible_enum_option'
           AND column_name  = 'name_es_do'
    ) THEN
        RAISE EXCEPTION
            'extensible_enum_option.name_es_do does not exist: run scripts/enable-spanish-labels.sh (or configure es_DO as an additional language and run `clear cache` + `sql diff --run`) first';
    END IF;
END
$$;

BEGIN;

UPDATE public.extensible_enum_option o
   SET name_es_do = v.label,
       modified_at = NOW()
  FROM public.extensible_enum_extensible_enum_option l,
       public.extensible_enum e,
       (VALUES
           ('compliance',     'Compliant',      'Cumple'),
           ('compliance',     'Non-compliant',  'No Cumple'),
           ('compliance',     'Not Applicable', 'No Aplica'),
           ('findingClass',   'A',              'Categoría A'),
           ('findingClass',   'B',              'Categoría B'),
           ('inspectorRoles', 'MAIN',           'Inspector Principal'),
           ('inspectorRoles', 'SECONDARY',      'Inspector Secundario'),
           ('inspectorRoles', 'TEAM_MEMBER',    'Miembro de Equipo')
       ) AS v(enum_code, option_code, label)
 WHERE l.extensible_enum_option_id = o.id
   AND e.id = l.extensible_enum_id
   AND v.enum_code = e.code
   AND v.option_code = o.code
   AND l.deleted = false
   AND o.deleted = false;

COMMIT;

\echo 'Vocabulary translations seeded: es_DO labels for compliance, findingClass and inspectorRoles.'
