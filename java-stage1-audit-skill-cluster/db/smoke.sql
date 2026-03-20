BEGIN;

SELECT to_regclass('public.stage1_runs') AS stage1_runs,
       to_regclass('public.stage1_pages') AS stage1_pages,
       to_regclass('public.stage1_classes') AS stage1_classes,
       to_regclass('public.stage1_warnings') AS stage1_warnings,
       to_regclass('public.stage1_sinks') AS stage1_sinks,
       to_regclass('public.stage1_routes') AS stage1_routes,
       to_regclass('public.stage1_auth_markers') AS stage1_auth_markers;

-- Optional: install helper functions/views in javaAudit before running large audits
-- Paste db/functions.sql, db/functions_write.sql and db/views.sql into execute_sql once.

CREATE TEMP TABLE stage1_smoke_ctx(rid TEXT PRIMARY KEY);

INSERT INTO stage1_smoke_ctx(rid)
VALUES ('smoke-' || md5(random()::text || clock_timestamp()::text));

INSERT INTO stage1_runs(run_id, source_path, output_path, page_size, total_classes, total_pages, status)
VALUES (
  (SELECT rid FROM stage1_smoke_ctx),
  '/tmp/source_path',
  '/tmp/output_path',
  100,
  150,
  2,
  'running'
)
ON CONFLICT (run_id) DO NOTHING;

INSERT INTO stage1_pages(run_id, page_no, status)
SELECT (SELECT rid FROM stage1_smoke_ctx), gs, 'pending'
FROM generate_series(0, 1) AS gs
ON CONFLICT (run_id, page_no) DO NOTHING;

UPDATE stage1_pages
SET status = 'in_progress',
    assigned_to = 'smoke-worker',
    assigned_at = now()
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx)
  AND page_no = 0
  AND status IN ('pending', 'needs_retry');

INSERT INTO stage1_classes(run_id, page_no, class_name, origin, status)
VALUES
  ((SELECT rid FROM stage1_smoke_ctx), 0, 'com.example.SmokeController', 'source', 'pending'),
  ((SELECT rid FROM stage1_smoke_ctx), 0, 'com.example.SmokeService', 'source', 'pending'),
  ((SELECT rid FROM stage1_smoke_ctx), 0, 'com.example.SmokeDao', 'source', 'pending')
ON CONFLICT (run_id, class_name) DO UPDATE
SET page_no = EXCLUDED.page_no,
    origin = COALESCE(stage1_classes.origin, EXCLUDED.origin);

UPDATE stage1_pages
SET expected_class_count = (
  SELECT COUNT(*) FROM stage1_classes
  WHERE run_id = (SELECT rid FROM stage1_smoke_ctx) AND page_no = 0
)
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx) AND page_no = 0;

INSERT INTO stage1_routes(
  run_id, worker_id, page_no, framework, http_method, path,
  class_name, method_name, method_descriptor, source_file, line_start, line_end, evidence
)
VALUES (
  (SELECT rid FROM stage1_smoke_ctx),
  'smoke-worker',
  0,
  'spring_mvc',
  'GET',
  '/smoke',
  'com.example.SmokeController',
  'ping',
  NULL,
  NULL,
  NULL,
  NULL,
  '{"reason":"@GetMapping(\"/smoke\")"}'::jsonb
);

INSERT INTO stage1_auth_markers(
  run_id, worker_id, page_no, marker_type, framework,
  class_name, method_name, method_descriptor, source_file, line_start, line_end,
  confidence, evidence
)
VALUES (
  (SELECT rid FROM stage1_smoke_ctx),
  'smoke-worker',
  0,
  'annotation',
  'spring_security',
  'com.example.SmokeController',
  'ping',
  NULL,
  NULL,
  NULL,
  NULL,
  'high',
  '{"reason":"@PreAuthorize present"}'::jsonb
);

INSERT INTO stage1_sinks(
  run_id, worker_id, page_no, class_name, method_name, method_descriptor,
  source_file, line_start, line_end, sink_type, framework, confidence, evidence
)
VALUES (
  (SELECT rid FROM stage1_smoke_ctx),
  'smoke-worker',
  0,
  'com.example.SmokeDao',
  'query',
  NULL,
  NULL,
  NULL,
  NULL,
  'sql',
  'jdbc',
  'high',
  '{"reason":"Statement.executeQuery(sql)","api":"java.sql.Statement#executeQuery","snippet":"stmt.executeQuery(sql)"}'::jsonb
);

UPDATE stage1_classes
SET status = 'done',
    done_at = now(),
    sink_count = CASE WHEN class_name = 'com.example.SmokeDao' THEN 1 ELSE 0 END,
    route_count = CASE WHEN class_name = 'com.example.SmokeController' THEN 1 ELSE 0 END,
    auth_marker_count = CASE WHEN class_name = 'com.example.SmokeController' THEN 1 ELSE 0 END,
    errors = '[]'::jsonb
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx)
  AND page_no = 0;

UPDATE stage1_pages
SET done_class_count = (
  SELECT COUNT(*) FROM stage1_classes
  WHERE run_id = (SELECT rid FROM stage1_smoke_ctx)
    AND page_no = 0
    AND status = 'done'
)
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx) AND page_no = 0;

UPDATE stage1_pages
SET status = 'done',
    new_sink_count = 1,
    new_route_count = 1,
    new_auth_marker_count = 1,
    error_count = 0,
    last_error = NULL
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx) AND page_no = 0;

UPDATE stage1_pages
SET status = 'done',
    expected_class_count = 0,
    done_class_count = 0
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx) AND page_no = 1;

INSERT INTO stage1_warnings(run_id, level, worker_id, page_no, class_name, message, details)
VALUES (
  (SELECT rid FROM stage1_smoke_ctx),
  'warning',
  'smoke-worker',
  0,
  'com.example.SmokeService',
  'smoke-warning',
  '{"type":"smoke"}'::jsonb
);

SELECT run_id, status, created_at, page_size, total_pages, total_classes
FROM stage1_runs
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

SELECT status, COUNT(*) AS cnt
FROM stage1_pages
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx)
GROUP BY status
ORDER BY cnt DESC, status;

SELECT
  COALESCE(SUM(done_class_count),0) AS done,
  COALESCE(SUM(expected_class_count),0) AS expected
FROM stage1_pages
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

SELECT COUNT(*) AS sinks_cnt
FROM stage1_sinks
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

SELECT COUNT(*) AS routes_cnt
FROM stage1_routes
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

SELECT COUNT(*) AS auth_markers_cnt
FROM stage1_auth_markers
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

SELECT time, level, worker_id, page_no, class_name, message
FROM stage1_warnings
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx)
ORDER BY time DESC
LIMIT 5;

-- Sanity: use helper function output shape (if installed)
-- SELECT * FROM stage1_run_progress((SELECT rid FROM stage1_smoke_ctx));
-- SELECT stage1_log_warning((SELECT rid FROM stage1_smoke_ctx),'warning','smoke-worker',0,NULL,'smoke-warning','{"type":"smoke"}'::jsonb);

DELETE FROM stage1_runs
WHERE run_id = (SELECT rid FROM stage1_smoke_ctx);

COMMIT;
