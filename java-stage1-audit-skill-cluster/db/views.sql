-- Stage1 DB helper views (PostgreSQL)
-- DB: javaAudit
-- Schema: public

CREATE OR REPLACE VIEW stage1_runs_latest AS
SELECT *
FROM stage1_runs
ORDER BY created_at DESC;

CREATE OR REPLACE VIEW stage1_pages_stuck AS
SELECT
  run_id,
  page_no,
  status,
  assigned_to,
  assigned_at,
  expected_class_count,
  done_class_count,
  last_error
FROM stage1_pages
WHERE status IN ('in_progress', 'needs_retry');

CREATE OR REPLACE VIEW stage1_classes_context_stats AS
SELECT
  run_id,
  code_context_level,
  COUNT(*) AS class_count
FROM stage1_classes
GROUP BY run_id, code_context_level;
