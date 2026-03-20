-- Stage1 审计数据库表结构（PostgreSQL）
-- DB: javaAudit
-- Schema: public

CREATE TABLE IF NOT EXISTS stage1_runs (
  run_id TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_path TEXT NOT NULL,
  output_path TEXT NOT NULL,
  page_size INTEGER NOT NULL DEFAULT 100,
  total_classes INTEGER,
  total_pages INTEGER,
  status TEXT NOT NULL DEFAULT 'running',
  notes JSONB NOT NULL DEFAULT '[]'::jsonb,
  CONSTRAINT stage1_runs_status_chk CHECK (status IN ('running','done','failed'))
);

CREATE TABLE IF NOT EXISTS stage1_pages (
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  page_no INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  assigned_to TEXT,
  assigned_at TIMESTAMPTZ,
  expected_class_count INTEGER,
  done_class_count INTEGER,
  new_sink_count INTEGER NOT NULL DEFAULT 0,
  new_route_count INTEGER NOT NULL DEFAULT 0,
  new_auth_marker_count INTEGER NOT NULL DEFAULT 0,
  error_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  PRIMARY KEY (run_id, page_no),
  CONSTRAINT stage1_pages_status_chk CHECK (status IN ('pending','in_progress','done','needs_retry'))
);

CREATE INDEX IF NOT EXISTS stage1_pages_run_status_idx
  ON stage1_pages(run_id, status, page_no);

CREATE TABLE IF NOT EXISTS stage1_classes (
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  page_no INTEGER NOT NULL,
  class_name TEXT NOT NULL,
  origin TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  code_context_level TEXT NOT NULL DEFAULT 'unknown',
  done_at TIMESTAMPTZ,
  sink_count INTEGER NOT NULL DEFAULT 0,
  route_count INTEGER NOT NULL DEFAULT 0,
  auth_marker_count INTEGER NOT NULL DEFAULT 0,
  errors JSONB NOT NULL DEFAULT '[]'::jsonb,
  PRIMARY KEY (run_id, class_name),
  CONSTRAINT stage1_classes_status_chk CHECK (status IN ('pending','done','error')),
  CONSTRAINT stage1_classes_code_context_level_chk CHECK (code_context_level IN ('unknown','members_only','method_source','class_source'))
);

CREATE INDEX IF NOT EXISTS stage1_classes_run_page_status_idx
  ON stage1_classes(run_id, page_no, status);

CREATE INDEX IF NOT EXISTS stage1_classes_run_context_idx
  ON stage1_classes(run_id, code_context_level);

CREATE TABLE IF NOT EXISTS stage1_warnings (
  id BIGSERIAL PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  time TIMESTAMPTZ NOT NULL DEFAULT now(),
  level TEXT NOT NULL DEFAULT 'warning',
  worker_id TEXT,
  page_no INTEGER,
  class_name TEXT,
  message TEXT NOT NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT stage1_warnings_level_chk CHECK (level IN ('warning','error'))
);

CREATE INDEX IF NOT EXISTS stage1_warnings_run_time_idx
  ON stage1_warnings(run_id, time DESC);

CREATE TABLE IF NOT EXISTS stage1_sinks (
  id BIGSERIAL PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  worker_id TEXT,
  page_no INTEGER NOT NULL,
  class_name TEXT NOT NULL,
  method_name TEXT NOT NULL,
  method_descriptor TEXT,
  source_file TEXT,
  line_start INTEGER,
  line_end INTEGER,
  sink_type TEXT NOT NULL,
  framework TEXT,
  confidence TEXT NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT stage1_sinks_confidence_chk CHECK (confidence IN ('high','medium','low')),
  CONSTRAINT stage1_sinks_sink_type_chk CHECK (sink_type IN (
    'sql','cmd_exec','ssrf','file_read','file_write','deserialize','xxe',
    'template','spel','ognl','jndi','ldap','runtime_reflect',
    'response_write','redirect','xpath','other'
  ))
);

CREATE INDEX IF NOT EXISTS stage1_sinks_run_page_idx
  ON stage1_sinks(run_id, page_no);

CREATE INDEX IF NOT EXISTS stage1_sinks_run_type_idx
  ON stage1_sinks(run_id, sink_type);

CREATE TABLE IF NOT EXISTS stage1_routes (
  id BIGSERIAL PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  worker_id TEXT,
  page_no INTEGER NOT NULL,
  framework TEXT NOT NULL,
  http_method TEXT NOT NULL,
  path TEXT NOT NULL,
  class_name TEXT NOT NULL,
  method_name TEXT,
  method_descriptor TEXT,
  source_file TEXT,
  line_start INTEGER,
  line_end INTEGER,
  evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT stage1_routes_framework_chk CHECK (framework IN ('spring_mvc','jax_rs','servlet','struts2','webservice','other')),
  CONSTRAINT stage1_routes_http_method_chk CHECK (http_method IN ('GET','POST','PUT','DELETE','PATCH','OPTIONS','HEAD','*'))
);

CREATE INDEX IF NOT EXISTS stage1_routes_run_path_idx
  ON stage1_routes(run_id, path);

CREATE TABLE IF NOT EXISTS stage1_auth_markers (
  id BIGSERIAL PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES stage1_runs(run_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  worker_id TEXT,
  page_no INTEGER NOT NULL,
  marker_type TEXT NOT NULL,
  framework TEXT NOT NULL,
  class_name TEXT NOT NULL,
  method_name TEXT,
  method_descriptor TEXT,
  source_file TEXT,
  line_start INTEGER,
  line_end INTEGER,
  confidence TEXT NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT stage1_auth_markers_confidence_chk CHECK (confidence IN ('high','medium','low')),
  CONSTRAINT stage1_auth_markers_marker_type_chk CHECK (marker_type IN (
    'filter','interceptor','aspect','annotation','config','middleware',
    'session','token','rbac','acl','other'
  )),
  CONSTRAINT stage1_auth_markers_framework_chk CHECK (framework IN ('spring_security','shiro','jwt','custom','unknown'))
);

CREATE INDEX IF NOT EXISTS stage1_auth_markers_run_type_idx
  ON stage1_auth_markers(run_id, marker_type);
