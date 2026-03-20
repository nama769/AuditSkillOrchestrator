-- Stage1 约束迁移（PostgreSQL）
-- 目标：统一枚举字段取值，避免出现 completed/done 混用等问题

BEGIN;

-- 1) 先做最小归一化（避免新增约束失败）
UPDATE stage1_pages SET status='done' WHERE status='completed';
UPDATE stage1_runs SET status='done' WHERE status='completed';
UPDATE stage1_classes SET status='done' WHERE status='completed';

-- 2) runs.status 约束：running/done/failed（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_runs
    ADD CONSTRAINT stage1_runs_status_chk
    CHECK (status IN ('running','done','failed'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 3) pages.status 约束：pending/in_progress/done/needs_retry（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_pages
    ADD CONSTRAINT stage1_pages_status_chk
    CHECK (status IN ('pending','in_progress','done','needs_retry'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 4) classes.status 约束：pending/done/error（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_classes
    ADD CONSTRAINT stage1_classes_status_chk
    CHECK (status IN ('pending','done','error'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 5) warnings.level 约束：warning/error（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_warnings
    ADD CONSTRAINT stage1_warnings_level_chk
    CHECK (level IN ('warning','error'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 6) sinks.confidence 约束：high/medium/low（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_sinks
    ADD CONSTRAINT stage1_sinks_confidence_chk
    CHECK (confidence IN ('high','medium','low'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 7) sinks.sink_type 约束（与 schema 一致，幂等）
DO $$
BEGIN
  ALTER TABLE stage1_sinks
    ADD CONSTRAINT stage1_sinks_sink_type_chk
    CHECK (sink_type IN (
      'sql','cmd_exec','ssrf','file_read','file_write','deserialize','xxe',
      'template','spel','ognl','jndi','ldap','runtime_reflect',
      'response_write','redirect','xpath','other'
    ));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 8) routes.framework/http_method 约束（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_routes
    ADD CONSTRAINT stage1_routes_framework_chk
    CHECK (framework IN ('spring_mvc','jax_rs','servlet','struts2','webservice','other'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE stage1_routes
    ADD CONSTRAINT stage1_routes_http_method_chk
    CHECK (http_method IN ('GET','POST','PUT','DELETE','PATCH','OPTIONS','HEAD','*'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- 9) auth_markers.marker_type/framework/confidence 约束（幂等）
DO $$
BEGIN
  ALTER TABLE stage1_auth_markers
    ADD CONSTRAINT stage1_auth_markers_confidence_chk
    CHECK (confidence IN ('high','medium','low'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE stage1_auth_markers
    ADD CONSTRAINT stage1_auth_markers_marker_type_chk
    CHECK (marker_type IN (
      'filter','interceptor','aspect','annotation','config','middleware',
      'session','token','rbac','acl','other'
    ));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE stage1_auth_markers
    ADD CONSTRAINT stage1_auth_markers_framework_chk
    CHECK (framework IN ('spring_security','shiro','jwt','custom','unknown'));
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMIT;
