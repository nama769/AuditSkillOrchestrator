-- Migration 002: add class code_context_level marker
-- Adds a lightweight marker to record whether a class was only member-scanned
-- or had method/class sources fetched.

ALTER TABLE stage1_classes
  ADD COLUMN IF NOT EXISTS code_context_level TEXT;

UPDATE stage1_classes
SET code_context_level = COALESCE(code_context_level, 'unknown');

ALTER TABLE stage1_classes
  ALTER COLUMN code_context_level SET DEFAULT 'unknown';

ALTER TABLE stage1_classes
  ALTER COLUMN code_context_level SET NOT NULL;

DO $$
BEGIN
  ALTER TABLE stage1_classes
    ADD CONSTRAINT stage1_classes_code_context_level_chk
    CHECK (code_context_level IN ('unknown','members_only','method_source','class_source'));
EXCEPTION
  WHEN duplicate_object THEN
    NULL;
END $$;

CREATE INDEX IF NOT EXISTS stage1_classes_run_context_idx
  ON stage1_classes(run_id, code_context_level);

