-- Rename the ProtocolQuestion entity's schema to ChecklistQuestion.
--
-- This is a pure rename (tables/columns/indexes), not a copy: no rows move,
-- no ids change. It must run BEFORE `install-metadata.sh` + `sql diff --run`
-- install the new ChecklistQuestion entity definition, so that `sql diff`
-- finds the renamed schema already matching AtroCore's naming convention for
-- ChecklistQuestion instead of proposing a fresh CREATE TABLE.
--
-- Verified against the live schema on 2026-09-06 (docker compose exec db
-- psql \d protocol_question / protocol_question_tag / etc.) before writing
-- this script -- do not assume these names if the target environment's
-- schema has drifted; re-verify with the same \d commands first.
--
-- The unique constraint on protocol_question.code
-- ("uniq_106e3c8777153098eb3b4e33") is a hash-derived name, not a
-- convention-derived one, and is intentionally left untouched here --
-- `sql diff --show` (run immediately after this script + install-metadata.sh)
-- will reveal whether AtroCore wants to drop/recreate it under a new hash;
-- that is expected and non-destructive (same column, same semantics).

BEGIN;

-- Main table
ALTER TABLE protocol_question RENAME TO checklist_question;
ALTER INDEX protocol_question_pkey RENAME TO checklist_question_pkey;
ALTER INDEX idx_protocol_question_name RENAME TO idx_checklist_question_name;
ALTER INDEX idx_protocol_question_created_at RENAME TO idx_checklist_question_created_at;
ALTER INDEX idx_protocol_question_created_by_id RENAME TO idx_checklist_question_created_by_id;
ALTER INDEX idx_protocol_question_modified_at RENAME TO idx_checklist_question_modified_at;
ALTER INDEX idx_protocol_question_modified_by_id RENAME TO idx_checklist_question_modified_by_id;
ALTER INDEX idx_protocol_question_specialty_id RENAME TO idx_checklist_question_specialty_id;
ALTER INDEX idx_protocol_question_topic_id RENAME TO idx_checklist_question_topic_id;

-- Tags join table (ProtocolQuestionTag -> ChecklistQuestionTag)
ALTER TABLE protocol_question_tag RENAME TO checklist_question_tag;
ALTER TABLE checklist_question_tag RENAME COLUMN protocol_question_id TO checklist_question_id;
ALTER INDEX protocol_question_tag_pkey RENAME TO checklist_question_tag_pkey;
ALTER INDEX idx_protocol_question_tag_created_at RENAME TO idx_checklist_question_tag_created_at;
ALTER INDEX idx_protocol_question_tag_created_by_id RENAME TO idx_checklist_question_tag_created_by_id;
ALTER INDEX idx_protocol_question_tag_modified_at RENAME TO idx_checklist_question_tag_modified_at;
ALTER INDEX idx_protocol_question_tag_modified_by_id RENAME TO idx_checklist_question_tag_modified_by_id;
ALTER INDEX idx_protocol_question_tag_protocol_question_id RENAME TO idx_checklist_question_tag_checklist_question_id;
ALTER INDEX idx_protocol_question_tag_tag_id RENAME TO idx_checklist_question_tag_tag_id;
ALTER INDEX idx_protocol_question_tag_unique_relation RENAME TO idx_checklist_question_tag_unique_relation;

-- Normativa join table (NormativaProtocolQuestion -> NormativaChecklistQuestion)
ALTER TABLE normativa_protocol_question RENAME TO normativa_checklist_question;
ALTER TABLE normativa_checklist_question RENAME COLUMN protocol_question_id TO checklist_question_id;
ALTER INDEX normativa_protocol_question_pkey RENAME TO normativa_checklist_question_pkey;
ALTER INDEX idx_normativa_protocol_question_created_at RENAME TO idx_normativa_checklist_question_created_at;
ALTER INDEX idx_normativa_protocol_question_created_by_id RENAME TO idx_normativa_checklist_question_created_by_id;
ALTER INDEX idx_normativa_protocol_question_modified_at RENAME TO idx_normativa_checklist_question_modified_at;
ALTER INDEX idx_normativa_protocol_question_modified_by_id RENAME TO idx_normativa_checklist_question_modified_by_id;
ALTER INDEX idx_normativa_protocol_question_normativa_id RENAME TO idx_normativa_checklist_question_normativa_id;
ALTER INDEX idx_normativa_protocol_question_protocol_question_id RENAME TO idx_normativa_checklist_question_checklist_question_id;
ALTER INDEX idx_normativa_protocol_question_unique_relation RENAME TO idx_normativa_checklist_question_unique_relation;

-- AtroCore's built-in "follow" table
ALTER TABLE user_followed_protocol_question RENAME TO user_followed_checklist_question;
ALTER TABLE user_followed_checklist_question RENAME COLUMN protocol_question_id TO checklist_question_id;
ALTER INDEX user_followed_protocol_question_pkey RENAME TO user_followed_checklist_question_pkey;
ALTER INDEX idx_user_followed_protocol_question_created_at RENAME TO idx_user_followed_checklist_question_created_at;
ALTER INDEX idx_user_followed_protocol_question_created_by_id RENAME TO idx_user_followed_checklist_question_created_by_id;
ALTER INDEX idx_user_followed_protocol_question_modified_at RENAME TO idx_user_followed_checklist_question_modified_at;
ALTER INDEX idx_user_followed_protocol_question_modified_by_id RENAME TO idx_user_followed_checklist_question_modified_by_id;
ALTER INDEX idx_user_followed_protocol_question_protocol_question_id RENAME TO idx_user_followed_checklist_question_checklist_question_id;
ALTER INDEX idx_user_followed_protocol_question_unique_relation RENAME TO idx_user_followed_checklist_question_unique_relation;
ALTER INDEX idx_user_followed_protocol_question_user_id RENAME TO idx_user_followed_checklist_question_user_id;

-- InspectionQuestion.protocolQuestion -> checklistQuestion link column
ALTER TABLE inspection_question RENAME COLUMN protocol_question_id TO checklist_question_id;
ALTER INDEX idx_inspection_question_protocol_question_id RENAME TO idx_inspection_question_checklist_question_id;

COMMIT;
