--
-- USOAP / risk vocabularies seed (AtroCore / AtroPIM)
--
-- WHY THIS EXISTS
-- ---------------
-- `ChecklistQuestion.riskLevel`, `UsoapProtocolQuestion.criticalElement`,
-- `UsoapProtocolQuestion.areaCode`, `UsoapEvidenceExpectation.artifactCategory`,
-- `InspectionQuestion.compliance`, `ActingInspector.role` and `Finding.class` are
-- `extensibleEnum`/`extensibleMultiEnum` fields, and the tracked entity definitions
-- in `metadata/entityDefs/` reference their vocabularies by hard-coded id:
--
--   ChecklistQuestion.riskLevel            -> a01kny6kktqe689xt03tsy539tj  (riskLevel)
--   UsoapProtocolQuestion.criticalElement  -> a01m00yh7jtea18cz0dsbx3ed4g  (usoapCriticalElement)
--   UsoapProtocolQuestion.areaCode         -> a01m00yhhnweebvy2zphrbhwdc4  (usoapAreaCode)
--   UsoapEvidenceExpectation.artifactCategory -> ext_usoap_artifact_cat    (usoapArtifactCategory)
--   InspectionQuestion.compliance          -> a01k5cgz2x2e0bbspakk3c5hf0a (compliance)
--   ActingInspector.role                   -> a01k60s39gce7ct0jrnbybszncc (inspectorRoles)
--   Finding.class                          -> a01k5cjq7hxeb9v2c6yrd8e54xs (findingClass)
--
-- AtroCore's extensible enums are created through the UI, and `metadata/` has no
-- home for them: `scripts/install-metadata.sh` synchronises entityDefs,
-- clientDefs, scopes and layouts only. So these vocabularies existed *only
-- in the database* — the same "lives only in the dump" gap as the operational
-- records that `seed-demo-dataset.sql` fixes, except this one is worse: without
-- them a fresh install cannot use the checklist catalog at all, because
-- `/checklist` resolves `riskLevelName`, `criticalElementName` and
-- `areaCodeName` through these enums and would render empty or garbage labels,
-- and the USOAP evidence report groups by them. `ActingInspector.role` and
-- `Finding.class` came in with the operational model (2026-09-16) and are caught
-- by `scripts/validate-seeds.py`, which fails the build when a tracked
-- definition references an enum this file does not create.
--
-- This is REQUIRED INFRASTRUCTURE, not demo data:
--   * the enum ids and option ids are the canonical ones already referenced by
--     every existing record, so seeding them cannot orphan real rows;
--   * `scripts/seed-demo-dataset.sh --remove` deliberately does NOT touch these
--     rows (it deletes `demo-%` ids only) — they must survive.
--
-- The option *ids* are AtroCore-generated in the original data. They are
-- reproduced verbatim here so that any record already pointing at them keeps
-- resolving; only the `extensibleEnumId`s are load-bearing for the metadata.
--
-- ADDITIVE: inserts only, `ON CONFLICT DO NOTHING`, so it never overwrites a
-- deployment that already has these vocabularies (or has customised them).
--
-- WHEN TO RUN
-- -----------
-- After the AtroCore schema exists, before seeding the checklist catalog:
--
--   ./scripts/seed-usoap-vocabularies.sh --yes
--   ./scripts/seed-nomenclatura.sh --yes
--   ./scripts/seed-demo-dataset.sh --yes
--

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The extensible enums the tracked entity definitions reference by id
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum (id, name, code, multilingual, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('a01kny6kktqe689xt03tsy539tj', 'Risk Level',              'riskLevel',             false, false, NOW(), NOW(), '1', '1'),
    ('a01m00yh7jtea18cz0dsbx3ed4g', 'USOAP Critical Element',  'usoapCriticalElement',  false, false, NOW(), NOW(), '1', '1'),
    ('a01m00yhhnweebvy2zphrbhwdc4', 'USOAP Area Code',         'usoapAreaCode',         false, false, NOW(), NOW(), '1', '1'),
    ('ext_usoap_artifact_cat',      'USOAP Artifact Category',  'usoapArtifactCategory', false, false, NOW(), NOW(), '1', '1'),
    ('a01k5cgz2x2e0bbspakk3c5hf0a', 'Compliance',               'compliance',            false, false, NOW(), NOW(), '1', '1'),
    ('a01k60s39gce7ct0jrnbybszncc', 'Inspector Roles',          'inspectorRoles',        true,  false, NOW(), NOW(), '1', '1'),
    ('a01k5cjq7hxeb9v2c6yrd8e54xs', 'Finding Class',            'findingClass',          true,  false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Options — Risk Level (4). `Medium` is what the existing catalog uses.
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('a01kny6my3bebmsk16tftcpgqgy', 'Low',      'Low',      10, false, NOW(), NOW(), '1', '1'),
    ('a01kny6nptsedzrrvt4yh1wwkz8', 'Medium',   'Medium',   20, false, NOW(), NOW(), '1', '1'),
    ('a01kny6p20qecjt1srcbvq1v99j', 'High',     'High',     30, false, NOW(), NOW(), '1', '1'),
    ('a01kny6pdqeea6stdw6hn7yv6p7', 'Critical', 'Critical', 40, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Options — USOAP Critical Element (CE-1 … CE-8)
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('a01m00yht41e3x98rc78kmhvz40', 'CE-1', 'CE-1', 1, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj2eye3xrkgj0e4yy3400', 'CE-2', 'CE-2', 2, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj2sne659acsgtnf82b6h', 'CE-3', 'CE-3', 3, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj33me7yrt4hx2jsh21kp', 'CE-4', 'CE-4', 4, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj3d9e9fb7j59wynx6239', 'CE-5', 'CE-5', 5, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj3qke5b92tesb8vrcc71', 'CE-6', 'CE-6', 6, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj420e5rsea7z7e6br2am', 'CE-7', 'CE-7', 7, false, NOW(), NOW(), '1', '1'),
    ('a01m00yj4cbe0r9pq5520v6kvcv', 'CE-8', 'CE-8', 8, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Options — USOAP Area Code (the 17 USOAP areas)
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('a01m00yjbqpeett9fgd5pjz2c63', 'ATS',   'ATS',   1,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjc10ea3vyn35gvx1ta0g', 'CNS',   'CNS',   2,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjcaee1ea816e9bzdp2f8', 'SAR',   'SAR',   3,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjckte4gbz9w576rj4tmv', 'AIM',   'AIM',   4,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjcx4e6yv9c8hg1qx3y19', 'SMS',   'SMS',   5,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjd6be3rbx3y13yjhxhes', 'MET',   'MET',   6,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjdfhe0dvwfpsg29atxzs', 'AGA',   'AGA',   7,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjds6e2csfrx59q05gqay', 'P/OPS', 'P/OPS', 8,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yje2jedta5wg6x1hsy6tx', 'CHT',   'CHT',   9,  false, NOW(), NOW(), '1', '1'),
    ('a01m00yjebpe029kb2dkyp07ytq', 'PEL',   'PEL',   10, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjenbe5e9z2vd5fj15feg', 'OPS',   'OPS',   11, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjeyged7asqftwdmb8we7', 'AIR',   'AIR',   12, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjf7ne9sbgn5yg6gawgaz', 'FAL',   'FAL',   13, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjfheec1r3kz7s8r8fwf7', 'AVSEC', 'AVSEC', 14, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjftnefbabq9kp5pfphnd', 'DG',    'DG',    15, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjg41eb3rm1zs0t7s75p3', 'ENV',   'ENV',   16, false, NOW(), NOW(), '1', '1'),
    ('a01m00yjgdcee28sshfr8mzdd8m', 'AIG',   'AIG',   17, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. Bind the options to their enum
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('vocab-link-risk-low',      'a01kny6kktqe689xt03tsy539tj', 'a01kny6my3bebmsk16tftcpgqgy', 10, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-risk-medium',   'a01kny6kktqe689xt03tsy539tj', 'a01kny6nptsedzrrvt4yh1wwkz8', 20, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-risk-high',     'a01kny6kktqe689xt03tsy539tj', 'a01kny6p20qecjt1srcbvq1v99j', 30, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-risk-critical', 'a01kny6kktqe689xt03tsy539tj', 'a01kny6pdqeea6stdw6hn7yv6p7', 40, false, NOW(), NOW(), '1', '1'),

    ('vocab-link-ce-1', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yht41e3x98rc78kmhvz40', 1, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-2', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj2eye3xrkgj0e4yy3400', 2, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-3', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj2sne659acsgtnf82b6h', 3, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-4', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj33me7yrt4hx2jsh21kp', 4, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-5', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj3d9e9fb7j59wynx6239', 5, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-6', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj3qke5b92tesb8vrcc71', 6, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-7', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj420e5rsea7z7e6br2am', 7, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-ce-8', 'a01m00yh7jtea18cz0dsbx3ed4g', 'a01m00yj4cbe0r9pq5520v6kvcv', 8, false, NOW(), NOW(), '1', '1'),

    ('vocab-link-area-ats',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjbqpeett9fgd5pjz2c63', 1,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-cns',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjc10ea3vyn35gvx1ta0g', 2,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-sar',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjcaee1ea816e9bzdp2f8', 3,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-aim',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjckte4gbz9w576rj4tmv', 4,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-sms',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjcx4e6yv9c8hg1qx3y19', 5,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-met',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjd6be3rbx3y13yjhxhes', 6,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-aga',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjdfhe0dvwfpsg29atxzs', 7,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-pops',  'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjds6e2csfrx59q05gqay', 8,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-cht',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yje2jedta5wg6x1hsy6tx', 9,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-pel',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjebpe029kb2dkyp07ytq', 10, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-ops',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjenbe5e9z2vd5fj15feg', 11, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-air',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjeyged7asqftwdmb8we7', 12, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-fal',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjf7ne9sbgn5yg6gawgaz', 13, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-avsec', 'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjfheec1r3kz7s8r8fwf7', 14, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-dg',    'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjftnefbabq9kp5pfphnd', 15, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-env',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjg41eb3rm1zs0t7s75p3', 16, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-area-aig',   'a01m00yhhnweebvy2zphrbhwdc4', 'a01m00yjgdcee28sshfr8mzdd8m', 17, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Options — USOAP Artifact Category (10)
--
-- Used by UsoapEvidenceExpectation.artifactCategory to say which population an
-- evidence expectation samples from rather than a single checklist item.
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('ext_uac_checklist',         'Checklist',          'Checklist',         10,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_inspection_report', 'InspectionReport',   'InspectionReport',  20,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_cap_execution',     'CAPExecution',       'CAPExecution',      30,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_audit_report',      'AuditReport',        'AuditReport',       40,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_training_record',   'TrainingRecord',     'TrainingRecord',    50,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_personnel_file',    'PersonnelFile',      'PersonnelFile',     60,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_manual',            'Manual',             'Manual',            70,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_license',           'License',            'License',           80,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_oversight_plan',    'OversightPlan',      'OversightPlan',     90,  false, NOW(), NOW(), '1', '1'),
    ('ext_uac_aerodrome_dossier', 'AerodromeDossier',   'AerodromeDossier',  100, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('vocab-link-artifact-checklist',  'ext_usoap_artifact_cat', 'ext_uac_checklist',         10,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-inspection', 'ext_usoap_artifact_cat', 'ext_uac_inspection_report', 20,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-cap',        'ext_usoap_artifact_cat', 'ext_uac_cap_execution',     30,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-audit',      'ext_usoap_artifact_cat', 'ext_uac_audit_report',      40,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-training',   'ext_usoap_artifact_cat', 'ext_uac_training_record',   50,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-personnel',  'ext_usoap_artifact_cat', 'ext_uac_personnel_file',    60,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-manual',     'ext_usoap_artifact_cat', 'ext_uac_manual',            70,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-license',    'ext_usoap_artifact_cat', 'ext_uac_license',           80,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-plan',       'ext_usoap_artifact_cat', 'ext_uac_oversight_plan',    90,  false, NOW(), NOW(), '1', '1'),
    ('vocab-link-artifact-dossier',    'ext_usoap_artifact_cat', 'ext_uac_aerodrome_dossier', 100, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. Options — Compliance (3), referenced by InspectionQuestion.compliance
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('a01k5ch4xh0e3qrbez341chrexp', 'Compliant',      'Compliant',      10, false, NOW(), NOW(), '1', '1'),
    ('a01k5ch5hc2e6wa2xb2dvp04fed', 'Non-compliant',  'Non-compliant',  20, false, NOW(), NOW(), '1', '1'),
    ('a01k5ch9n9pe2gbfw2byz9h9ere', 'Not Applicable', 'Not Applicable', 30, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('vocab-link-compliance-compliant',    'a01k5cgz2x2e0bbspakk3c5hf0a', 'a01k5ch4xh0e3qrbez341chrexp', 10, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-compliance-noncompliant', 'a01k5cgz2x2e0bbspakk3c5hf0a', 'a01k5ch5hc2e6wa2xb2dvp04fed', 20, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-compliance-na',           'a01k5cgz2x2e0bbspakk3c5hf0a', 'a01k5ch9n9pe2gbfw2byz9h9ere', 30, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. Options — Inspector Roles (3), referenced by ActingInspector.role
--
-- `multilingual`, so the Spanish label lives in `name_es_do` rather than `name`.
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id, name_es_do) VALUES
    ('a01k60s4sstea0awdgtgaq3gnrz', 'Main Inspector',      'MAIN',        85606557, false, NOW(), NOW(), '1', '1', 'Inspector Principal'),
    ('a01k60s618se9mth8aq77qvzxcg', 'Secondary Inspector', 'SECONDARY',   85606578, false, NOW(), NOW(), '1', '1', 'Inspector Secundario'),
    ('a01k60s6v3xe2hag3whymmafze3', 'Team Member',         'TEAM_MEMBER', 86284346, false, NOW(), NOW(), '1', '1', 'Miembro de Equipo')
ON CONFLICT DO NOTHING;

INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('vocab-link-inspector-main',      'a01k60s39gce7ct0jrnbybszncc', 'a01k60s4sstea0awdgtgaq3gnrz', 85606557, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-inspector-secondary', 'a01k60s39gce7ct0jrnbybszncc', 'a01k60s618se9mth8aq77qvzxcg', 85606578, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-inspector-team',      'a01k60s39gce7ct0jrnbybszncc', 'a01k60s6v3xe2hag3whymmafze3', 86284346, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. Options — Finding Class (2), referenced by Finding.class
-- ---------------------------------------------------------------------------
INSERT INTO public.extensible_enum_option (id, name, code, sort_order, deleted, created_at, modified_at, created_by_id, modified_by_id, name_es_do) VALUES
    ('a01k5cjtbw2ecvv5pdhwr767caw', 'Category A', 'A', 85606557, false, NOW(), NOW(), '1', '1', 'Categoría A'),
    ('a01k5cjtzxde8kt2vzkzkss45f1', 'Category B', 'B', 85606578, false, NOW(), NOW(), '1', '1', 'Categoría B')
ON CONFLICT DO NOTHING;

INSERT INTO public.extensible_enum_extensible_enum_option (id, extensible_enum_id, extensible_enum_option_id, sorting, deleted, created_at, modified_at, created_by_id, modified_by_id) VALUES
    ('vocab-link-findingclass-a', 'a01k5cjq7hxeb9v2c6yrd8e54xs', 'a01k5cjtbw2ecvv5pdhwr767caw', 85606557, false, NOW(), NOW(), '1', '1'),
    ('vocab-link-findingclass-b', 'a01k5cjq7hxeb9v2c6yrd8e54xs', 'a01k5cjtzxde8kt2vzkzkss45f1', 85606578, false, NOW(), NOW(), '1', '1')
ON CONFLICT DO NOTHING;

COMMIT;
