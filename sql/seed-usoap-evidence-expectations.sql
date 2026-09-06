--
-- USOAP evidence-expectation catalog seed (AtroCore / AtroPIM)
--
-- Populates the new `UsoapEvidenceExpectation` entity: one row per USOAP
-- Protocol Question whose "Orientación para el examen de pruebas" guidance
-- (in the root-level `tabla pqs AGA.csv` / `tabla pqs ANS.csv` source tables)
-- asks an examiner to sample or review a whole artifact/population -- a
-- checklist, an inspection/audit report, a CAP follow-up, a manual, a
-- license, a training/personnel record, an aerodrome dossier, or an
-- oversight plan -- rather than one specific checklist item.
--
-- This is what `POST /api/usoap/ce-evidence-report` (compliance_cmis) uses
-- to resolve "Type-2" PQs by running a live query against a document
-- population, instead of requiring every such document to be individually
-- tagged (see compliance_cmis/docs/usoap-evidence-structure.md).
--
-- WHEN TO RUN
-- -----------
-- After the stack is up AND AtroCore has applied the schema implied by
-- metadata/entityDefs/UsoapEvidenceExpectation.json (see
-- scripts/install-metadata.sh, then `console.php clear cache` and
-- `console.php sql diff --run`). That step creates the
-- `usoap_evidence_expectation` table; this script only fills in rows.
-- It also requires `usoap_protocol_question` to already be populated (the
-- PQ catalog imported separately), since each row here resolves its parent
-- PQ by `code`.
--
-- HOW TO RUN
-- ----------
--   ./scripts/seed-usoap-evidence-expectations.sh --yes   (preferred wrapper)
--
-- Or directly:
--   docker compose exec -T db psql -U "$POSTGRES_PIM_USER" -d "$POSTGRES_PIM_DB" \
--     -v ON_ERROR_STOP=1 < sql/seed-usoap-evidence-expectations.sql
--
-- IDEMPOTENT / DESTRUCTIVE SCOPE: replaces every row in
-- `usoap_evidence_expectation` and re-syncs the `usoap_artifact_category`
-- extensible-enum options. Nothing outside those two is touched.
--
-- IDs are deterministic and human-readable (varchar(36)), matching the
-- convention in seed-nomenclatura-catalog.sql, so re-running this script is
-- a no-op rather than a duplicate-insert.
--
-- PROVENANCE / CAVEAT: this is a first-pass backfill derived mechanically
-- from the two source CSVs' guidance text (rows matching "muestra",
-- "muestreo", "ejemplares", or CAP-follow-up sampling language). Each row
-- carries its `guidance_excerpt` and `source_file` so a compliance officer
-- can verify/correct the `artifact_category` and `area_code` classification
-- against the original PQ text -- these are reasonable first classifications,
-- not an authoritative recodification of the USOAP protocol.
--

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Safety net: create `usoap_evidence_expectation` if the AtroCore schema
-- sync has not run yet. Shape mirrors the entityDef field set; extensibleEnum
-- columns (artifact_category, critical_element) store the option id as
-- varchar, extensibleMultiEnum (area_code) stores a JSON array as text,
-- exactly like the existing usoap_protocol_question table.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.usoap_evidence_expectation (
    id                          character varying(36)  NOT NULL,
    name                        character varying(255) DEFAULT NULL::character varying,
    deleted                     boolean                DEFAULT false,
    created_at                  timestamp(0) without time zone DEFAULT NULL::timestamp without time zone,
    modified_at                 timestamp(0) without time zone DEFAULT NULL::timestamp without time zone,
    created_by_id               character varying(36)  DEFAULT NULL::character varying,
    modified_by_id              character varying(36)  DEFAULT NULL::character varying,
    pq_code                     character varying(255) DEFAULT NULL::character varying,
    usoap_protocol_question_id  character varying(36)  DEFAULT NULL::character varying,
    artifact_category           character varying(255) DEFAULT NULL::character varying,
    sample_required             boolean                DEFAULT true,
    critical_element            character varying(255) DEFAULT NULL::character varying,
    area_code                   text,
    specialty_code              character varying(255) DEFAULT NULL::character varying,
    date_range_hint_months      integer,
    query_hint                  text,
    guidance_excerpt            text,
    source_file                 character varying(255) DEFAULT NULL::character varying
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.usoap_evidence_expectation'::regclass
           AND contype  = 'p'
    ) THEN
        ALTER TABLE public.usoap_evidence_expectation ADD PRIMARY KEY (id);
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Safety net: the `usoap_artifact_category` extensible-enum group, in case
-- the admin UI hasn't been used to create it yet. `criticalElement`/
-- `areaCode` on UsoapEvidenceExpectation deliberately reuse the extensible
-- enums already seeded for UsoapProtocolQuestion (a01m00yh7jtea18cz0dsbx3ed4g
-- / a01m00yhhnweebvy2zphrbhwdc4) -- only this one is new.
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum (id, name, code, multilingual, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES ('ext_usoap_artifact_cat', 'USOAP Artifact Category', 'usoapArtifactCategory', false, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES
    ('ext_uac_checklist',          'Checklist',          'Checklist',          10,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_inspection_report',  'InspectionReport',   'InspectionReport',   20,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_cap_execution',      'CAPExecution',       'CAPExecution',       30,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_audit_report',       'AuditReport',        'AuditReport',        40,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_training_record',    'TrainingRecord',     'TrainingRecord',     50,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_personnel_file',     'PersonnelFile',      'PersonnelFile',      60,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_manual',             'Manual',             'Manual',             70,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_license',            'License',            'License',            80,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_oversight_plan',     'OversightPlan',      'OversightPlan',      90,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_aerodrome_dossier',  'AerodromeDossier',   'AerodromeDossier',   100, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES
    ('ext_uac_link_checklist',          'ext_usoap_artifact_cat', 'ext_uac_checklist',          10,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_inspection_report',  'ext_usoap_artifact_cat', 'ext_uac_inspection_report',  20,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_cap_execution',      'ext_usoap_artifact_cat', 'ext_uac_cap_execution',      30,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_audit_report',       'ext_usoap_artifact_cat', 'ext_uac_audit_report',       40,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_training_record',    'ext_usoap_artifact_cat', 'ext_uac_training_record',    50,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_personnel_file',     'ext_usoap_artifact_cat', 'ext_uac_personnel_file',     60,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_manual',             'ext_usoap_artifact_cat', 'ext_uac_manual',             70,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_license',            'ext_usoap_artifact_cat', 'ext_uac_license',            80,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_oversight_plan',     'ext_usoap_artifact_cat', 'ext_uac_oversight_plan',     90,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_link_aerodrome_dossier',  'ext_usoap_artifact_cat', 'ext_uac_aerodrome_dossier',  100, false, NOW(), NOW(), '1', '1')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Evidence-expectation rows, backfilled from tabla pqs AGA.csv / tabla pqs
-- ANS.csv. `usoap_protocol_question_id` is resolved by `code` at insert time
-- rather than hard-coded, since PQ ids are AtroCore-generated (not ours to
-- fix); a NULL here means the PQ catalog hasn't been imported yet for that
-- code and the row is skipped from the WHERE-matched insert (see the
-- diagnostic query after the DELETE below).
-- ---------------------------------------------------------------------------
DELETE FROM public.usoap_evidence_expectation;

INSERT INTO public.usoap_evidence_expectation
    (id, name, pq_code, usoap_protocol_question_id, artifact_category, sample_required,
     critical_element, area_code, specialty_code, date_range_hint_months,
     guidance_excerpt, source_file, deleted, created_at, modified_at, created_by_id, modified_by_id)
VALUES
    ('uee_aga_8042', 'PQ 8.042 — PersonnelFile sample', 'PQ 8.042', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.042'), 'ext_uac_personnel_file', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar unas muestras de expedientes de contratación. 2) Cotejar con los requisitos establecidos.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8048', 'PQ 8.048 — CAPExecution sample', 'PQ 8.048', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.048'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, 'Examinar muestras de medidas correctivas adoptadas para resolver las deficiencias detectadas durante las actividades de vigilancia de las entidades o personas objeto de la delegación.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8057', 'PQ 8.057 — TrainingRecord sample', 'PQ 8.057', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.057'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar los requisitos e instrucciones existentes para la creación y mantenimiento de registros de instrucción. 2) Examinar el sistema establecido y hacer un muestreo de los registros de instrucción. 3) Verificar que los registros de instrucción: a) se retengan de manera sistemática; y b) conten', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8086', 'PQ 8.086 — AerodromeDossier sample', 'PQ 8.086', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.086'), 'ext_uac_aerodrome_dossier', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Verificar si se aplican los requisitos de certificación a todos los aeródromos designados. 2) Examinar muestras de registros de certificación de aeródromos para confirmar que el proceso de certificación de los aeródromos designados se aplica de manera uniforme.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8103', 'PQ 8.103 — AerodromeDossier sample', 'PQ 8.103', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.103'), 'ext_uac_aerodrome_dossier', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar el sistema de archivo de la autoridad de reglamentación de aeródromos. 2) Examinar pruebas para confirmar que los expedientes de los aeródromos contienen la documentación necesaria (p. ej., formularios, manuales, listas de verificación, etc.).', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8111', 'PQ 8.111 — Manual sample', 'PQ 8.111', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.111'), 'ext_uac_manual', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Verificar que la CAA ha aprobado/aceptado los manuales de aeródromo para todos los aeródromos designados. 2) Examinar algunos ejemplares de manuales de aeródromo aprobados/aceptados, específicamente los detalles sobre: a) el emplazamiento del aeródromo; b) la información sobre el aeródromo que de', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8115', 'PQ 8.115 — Manual sample', 'PQ 8.115', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.115'), 'ext_uac_manual', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Evaluar el mecanismo de revisión periódica. 2) Verificar que la autoridad de reglamentación de aeródromos tenga copias actualizadas de los manuales de aeródromo aprobados 3) Examinar pruebas para confirmar la aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8161', 'PQ 8.161 — InspectionReport sample', 'PQ 8.161', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.161'), 'ext_uac_inspection_report', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar el sistema de evaluación, incluida una muestra de la evaluación de las características físicas, instalaciones y equipo de aeródromo según se detalla en los documentos de referencia de la OACI. 2) Examinar pruebas para confirmar la aplicación efectiva. 3) Verificar que, cuando se detecten', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8181', 'PQ 8.181 — OversightPlan sample', 'PQ 8.181', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.181'), 'ext_uac_oversight_plan', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar pruebas documentales de los arreglos. 2) Evaluar el mecanismo establecido por el Estado para asegurarse de la aplicación efectiva. 3) Examinar muestras.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8291', 'PQ 8.291 — Manual sample', 'PQ 8.291', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.291'), 'ext_uac_manual', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar pruebas para confirmar la efectiva aplicación, cooperación y coordinación. 2) Hacer un muestreo de planes de emergencia. 3) Comprobar la inclusión de: a) emergencias que puedan ocurrir en las inmediaciones del aeródromo; y b) emergencias de salud pública, incluida la coordinación con los', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8315', 'PQ 8.315 — TrainingRecord sample', 'PQ 8.315', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.315'), 'ext_uac_training_record', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Verificar los requisitos nacionales de instrucción sobre salvamento y extinción de incendios (RFF). 2) Examinar pruebas para confirmar la aplicación efectiva. 3) Verificar la vigilancia del adiestramiento y su evaluación, incluido el adiestramiento en el combate de incendios alimentados por combu', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8365', 'PQ 8.365 — Manual sample', 'PQ 8.365', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.365'), 'ext_uac_manual', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Verificar los reglamentos. 2) Examinar pruebas documentales para confirmar la aplicación efectiva (por ej., el sistema de vigilancia que utiliza un aeródromo, según se manifieste en un procedimiento de un manual de aeródromo).', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8385', 'PQ 8.385 — AuditReport sample', 'PQ 8.385', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.385'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Evaluar el mecanismo establecido por el Estado para asegurarse de la aplicación efectiva. 2) Analizar una muestra de informes de inspección/auditoría para confirmar la aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8387', 'PQ 8.387 — AuditReport sample', 'PQ 8.387', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.387'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar los requisitos establecidos. 2) Evaluar el mecanismo establecido por el Estado para asegurarse de la aplicación efectiva. 3) Analizar una muestra de informes de inspección/auditoría para confirmar la aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8389', 'PQ 8.389 — AuditReport sample', 'PQ 8.389', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.389'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar los requisitos establecidos. 2) Evaluar el mecanismo establecido por el Estado para asegurarse de la aplicación efectiva. 3) Analizar una muestra de informes de inspección/auditoría para confirmar la a aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8393', 'PQ 8.393 — AuditReport sample', 'PQ 8.393', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.393'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar los requisitos establecidos. 2) Evaluar el mecanismo establecido por el Estado para asegurarse de la aplicación efectiva. 3) Analizar una muestra de informes de inspección/auditoría para confirmar la aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8395', 'PQ 8.395 — AuditReport sample', 'PQ 8.395', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.395'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar los requisitos establecidos. 2) Evaluar el mecanismo que garantiza la aplicación efectiva. 3) Analizar una muestra de informes de inspección/auditoría para confirmar la aplicación efectiva.', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8403', 'PQ 8.403 — OversightPlan sample', 'PQ 8.403', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.403'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Examinar el programa y el plan de vigilancia del año anterior y del año en curso. 2) Confirmar la frecuencia apropiada de las inspecciones u otras actividades. 3) Confirmar la inclusión de auditorías e inspecciones periódicas y no periódicas. 4) La vigilancia debe abarcar todos los aspectos de la', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_aga_8937', 'PQ 8.937 — PersonnelFile sample', 'PQ 8.937', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 8.937'), 'ext_uac_personnel_file', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjdfhe0dvwfpsg29atxzs"]', 'AGA', 24, '1) Verificar que el Estado ha establecido e implementado un mecanismo para validar que el personal de los explotadores de aeródromo implicado en el SMS esté cualificado para desempeñar sus funciones y responsabilidades. 2) Hacer un muestreo de los registros de actividades de vigilancia. Notas para e', 'AGA', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7057', 'PQ 7.057 — License sample', 'PQ 7.057', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.057'), 'ext_uac_license', true, 'a01m00yj2sne659acsgtnf82b6h', NULL, NULL, 24, '1) Examinar las descripciones de los puestos de los inspectores ATS. 2) Verificar que los criterios de cualificación incluyan: a) licencias y habilitaciones para el control del tránsito aéreo compatibles con las responsabilidades de sus puestos; y b) experiencia práctica y técnica acorde con los ser', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7060', 'PQ 7.060 — PersonnelFile sample', 'PQ 7.060', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.060'), 'ext_uac_personnel_file', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjckte4gbz9w576rj4tmv","a01m00yjbqpeett9fgd5pjz2c63","a01m00yjc10ea3vyn35gvx1ta0g","a01m00yjd6be3rbx3y13yjhxhes","a01m00yjds6e2csfrx59q05gqay","a01m00yjcaee1ea816e9bzdp2f8"]', 'AIM,ATS,COM,NAV,SUR,ECNS,EMET,P/OPS,MET,SAR', 24, '1) Examinar unas muestras de expedientes de contratación. 2) Cotejar con los requisitos establecidos. Nota para el/la auditor(a): Esta PQ cubre: AIS, ATS, CNS, Diseño de procedimientos de vuelo, MET y SAR.', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7063', 'PQ 7.063 — OversightPlan sample', 'PQ 7.063', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.063'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjbqpeett9fgd5pjz2c63"]', 'ATS', 24, '1) Verificar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Comprobar que el plan concuerde co', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7069', 'PQ 7.069 — TrainingRecord sample', 'PQ 7.069', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.069'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjbqpeett9fgd5pjz2c63"]', 'ATS', 24, '1) Hacer un muestreo de planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que rec', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7073', 'PQ 7.073 — TrainingRecord sample', 'PQ 7.073', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.073'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', NULL, NULL, 24, '1) Examinar las instrucciones o requisitos para la creación y mantenimiento de registros de instrucción. 2) Examinar el sistema establecido. 3) Examinar muestras de registros de instrucción. 4) Verificar que los registros de instrucción se conserven de forma sistemática, incluidos los registros de e', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7081', 'PQ 7.081 — InspectionReport sample', 'PQ 7.081', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.081'), 'ext_uac_inspection_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjbqpeett9fgd5pjz2c63"]', 'ATS', 24, '1) Examinar el mecanismo establecido para asegurar el cumplimiento. 2) Examinar si el Estado se asegura de que la capacidad ATS se examine periódicamente. 3) Hacer un muestreo de capacidades ATC evaluadas de los sectores de control y aeródromos.', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7121', 'PQ 7.121 — AuditReport sample', 'PQ 7.121', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.121'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjbqpeett9fgd5pjz2c63"]', 'ATS', 24, '1) Examinar el mecanismo que ha establecido el Estado para asegurar la aplicación efectiva (incluida la revisión de procedimientos de operaciones con escasa visibilidad). 2) Hacer un muestreo de pruebas documentales de los procedimientos que se aplican para controlar el movimiento de personas y vehí', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7199', 'PQ 7.199 — CAPExecution sample', 'PQ 7.199', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.199'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjbqpeett9fgd5pjz2c63"]', 'ATS', 24, '1) Examinar la lista de deficiencias detectadas en las actividades de vigilancia y las medidas correctivas previstas o tomadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de m', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7215', 'PQ 7.215 — TrainingRecord sample', 'PQ 7.215', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.215'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjds6e2csfrx59q05gqay"]', 'P/OPS', 24, '1) Hacer un muestreo de planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que rec', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7231', 'PQ 7.231 — OversightPlan sample', 'PQ 7.231', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.231'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjds6e2csfrx59q05gqay"]', 'P/OPS', 24, '1) Verificar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Comprobar que el plan concuerde co', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7233', 'PQ 7.233 — CAPExecution sample', 'PQ 7.233', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.233'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjds6e2csfrx59q05gqay"]', 'P/OPS', 24, '1) Examinar la lista de deficiencias detectadas en las actividades de vigilancia y las medidas correctivas previstas o tomadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de m', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7234', 'PQ 7.234 — AuditReport sample', 'PQ 7.234', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.234'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjds6e2csfrx59q05gqay"]', 'P/OPS', 24, '1) Examinar el mecanismo establecido para asegurar la aplicación efectiva. 2) Hacer un muestreo de la documentación relacionada con los exámenes periódicos realizados y verificar que sigan siendo válidos en lo que respecta a los márgenes mínimos de franqueamiento de obstáculos. 3) Confirmar que el i', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7253', 'PQ 7.253 — InspectionReport sample', 'PQ 7.253', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.253'), 'ext_uac_inspection_report', true, 'a01m00yj3qke5b92tesb8vrcc71', '["a01m00yjds6e2csfrx59q05gqay"]', 'P/OPS', 24, '1) Examinar el proceso de aprobación establecido e implantado para asegurar la aplicación efectiva. 2) Verificar que los procedimientos estén aprobados antes de su publicación en la AIP. 3) Hacer un muestreo de los registros de las aprobaciones de procedimientos de vuelo publicados en la AIP.', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7281', 'PQ 7.281 — TrainingRecord sample', 'PQ 7.281', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.281'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjckte4gbz9w576rj4tmv"]', 'AIM', 24, '1) Hacer un muestreo de planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que rec', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7287', 'PQ 7.287 — OversightPlan sample', 'PQ 7.287', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.287'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjckte4gbz9w576rj4tmv"]', 'AIM', 24, '1) Verificar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Comprobar que el plan concuerde co', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7289', 'PQ 7.289 — CAPExecution sample', 'PQ 7.289', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.289'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjckte4gbz9w576rj4tmv"]', 'AIM', 24, '1) Examinar la lista de deficiencias detectadas en las actividades de vigilancia y las medidas correctivas previstas o adoptadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7291', 'PQ 7.291 — OversightPlan sample', 'PQ 7.291', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.291'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjckte4gbz9w576rj4tmv"]', 'AIM', 24, '1) Examinar el mecanismo establecido para asegurar la aplicación efectiva. 2) Confirmar que los arreglos formales estén vigentes y actualizados con los iniciadores de datos aeronáuticos y que sean acordes al catálogo de datos aeronáuticos. 3) Examinar los arreglos con las autoridades de vigilancia y', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7385', 'PQ 7.385 — TrainingRecord sample', 'PQ 7.385', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.385'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjc10ea3vyn35gvx1ta0g","a01m00yjd6be3rbx3y13yjhxhes"]', 'COM,SUR,NAV,ECNS,EMET', 24, '1) Hacer un muestreo de planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que rec', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7391', 'PQ 7.391 — OversightPlan sample', 'PQ 7.391', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.391'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjc10ea3vyn35gvx1ta0g","a01m00yjd6be3rbx3y13yjhxhes"]', 'COM,SUR,NAV,ECNS,EMET', 24, '1) Verificar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Comprobar que el plan concuerde co', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7395', 'PQ 7.395 — CAPExecution sample', 'PQ 7.395', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.395'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjc10ea3vyn35gvx1ta0g","a01m00yjd6be3rbx3y13yjhxhes"]', 'COM,SUR,NAV,ECNS,EMET', 24, '1) Examinar la lista de deficiencias detectadas en las actividades de vigilancia y las medidas correctivas previstas o adoptadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7429', 'PQ 7.429 — TrainingRecord sample', 'PQ 7.429', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.429'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjd6be3rbx3y13yjhxhes"]', 'MET', 24, '1) Hacer un muestreo de los planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7435', 'PQ 7.435 — OversightPlan sample', 'PQ 7.435', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.435'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjd6be3rbx3y13yjhxhes"]', 'MET', 24, '1) Verificar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Comprobar que el plan concuerde co', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7437', 'PQ 7.437 — CAPExecution sample', 'PQ 7.437', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.437'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjd6be3rbx3y13yjhxhes"]', 'MET', 24, '1) Examinar la lista de deficiencias detectadas durante una inspección y las medidas correctivas previstas o adoptadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de medidas c', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7465', 'PQ 7.465 — AuditReport sample', 'PQ 7.465', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.465'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjd6be3rbx3y13yjhxhes"]', 'MET', 24, '1) Examinar el mecanismo establecido para asegurar la aplicación efectiva. 2) Hacer un muestreo en un aeródromo de las evaluaciones llevadas a cabo con la autoridad ATS y los explotadores de servicios aéreos para determinar si la cizalladura del viento es un factor de seguridad operacional a tener e', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7467', 'PQ 7.467 — AuditReport sample', 'PQ 7.467', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.467'), 'ext_uac_audit_report', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjd6be3rbx3y13yjhxhes"]', 'MET', 24, '1) Examinar el mecanismo establecido para asegurar la aplicación efectiva. 2) Hacer un muestreo de los criterios establecidos por el proveedor de servicios MET para un aeródromo (en consulta con el proveedor de ATS y el explotador).', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7499', 'PQ 7.499 — TrainingRecord sample', 'PQ 7.499', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.499'), 'ext_uac_training_record', true, 'a01m00yj33me7yrt4hx2jsh21kp', '["a01m00yjcaee1ea816e9bzdp2f8"]', 'SAR', 24, '1) Hacer un muestreo de planes de instrucción recientes para distintos inspectores. 2) Verificar que los planes de instrucción estén basados en el programa de instrucción e incluyan: a) los tipos de instrucción detallados; b) las prioridades; y c) la duración. 3) Verificar que la instrucción que rec', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7505', 'PQ 7.505 — OversightPlan sample', 'PQ 7.505', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.505'), 'ext_uac_oversight_plan', true, 'a01m00yj420e5rsea7z7e6br2am', '["a01m00yjcaee1ea816e9bzdp2f8"]', 'SAR', 24, '1) Examinar que el programa de vigilancia incluya: a) los tipos de actividades de vigilancia (auditorías, inspecciones, análisis de sucesos de seguridad operacional, etc.); b) el calendario o la frecuencia de las actividades; y c) el alcance de las actividades. 2) Confirmar que el plan concuerde con', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7507', 'PQ 7.507 — CAPExecution sample', 'PQ 7.507', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.507'), 'ext_uac_cap_execution', true, 'a01m00yj4cbe0r9pq5520v6kvcv', '["a01m00yjcaee1ea816e9bzdp2f8"]', 'SAR', 24, '1) Examinar la lista de deficiencias detectadas durante una inspección y las medidas correctivas previstas y adoptadas. 2) Examinar el mecanismo para asesorar, establecer plazos, revisar y aceptar, y hacer un seguimiento de las acciones para verificar la ejecución efectiva de los planes de medidas c', 'ANS', false, NOW(), NOW(), '1', '1'),
    ('uee_ans_7937', 'PQ 7.937 — PersonnelFile sample', 'PQ 7.937', (SELECT id FROM public.usoap_protocol_question WHERE code = 'PQ 7.937'), 'ext_uac_personnel_file', true, 'a01m00yj420e5rsea7z7e6br2am', NULL, NULL, 24, '1) Verificar que el Estado haya establecido e implementado un mecanismo para validar que el personal de los proveedores de ATS implicado en el SMS esté calificado para desempeñar sus funciones y responsabilidades. 2) Hacer un muestreo de los registros de actividades de vigilancia. Notas para el/la a', 'ANS', false, NOW(), NOW(), '1', '1');

-- Rows whose PQ code has no match in usoap_protocol_question (catalog not
-- imported yet, or code drifted) end up with a NULL FK rather than failing
-- the insert -- surface them so they don't silently go unresolved.
DO $$
DECLARE
    unresolved_count integer;
BEGIN
    SELECT count(*) INTO unresolved_count
      FROM public.usoap_evidence_expectation
     WHERE usoap_protocol_question_id IS NULL;
    IF unresolved_count > 0 THEN
        RAISE NOTICE '% UsoapEvidenceExpectation row(s) could not resolve usoap_protocol_question_id -- their pq_code has no matching usoap_protocol_question.code yet.', unresolved_count;
    END IF;
END
$$;

COMMIT;

\echo 'USOAP evidence-expectation catalog seeded: 48 rows (19 AGA, 29 ANS).'
