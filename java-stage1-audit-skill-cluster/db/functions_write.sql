-- Stage1 DB write helpers (PostgreSQL)
-- DB: javaAudit
-- Schema: public

CREATE OR REPLACE FUNCTION stage1_log_warning(
  p_run_id TEXT,
  p_level TEXT,
  p_worker_id TEXT,
  p_page_no INTEGER,
  p_class_name TEXT,
  p_message TEXT,
  p_details JSONB DEFAULT '{}'::jsonb
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF p_message IS NULL OR length(trim(p_message)) = 0 THEN
    RAISE EXCEPTION 'warning message must not be empty';
  END IF;

  INSERT INTO stage1_warnings(run_id, level, worker_id, page_no, class_name, message, details)
  VALUES (p_run_id, COALESCE(p_level,'warning'), p_worker_id, p_page_no, p_class_name, p_message, COALESCE(p_details,'{}'::jsonb))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_upsert_class(
  p_run_id TEXT,
  p_page_no INTEGER,
  p_class_name TEXT,
  p_origin TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_class_name IS NULL OR length(trim(p_class_name)) = 0 THEN
    RAISE EXCEPTION 'class_name must not be empty';
  END IF;

  INSERT INTO stage1_classes(run_id, page_no, class_name, origin, status)
  VALUES (p_run_id, p_page_no, p_class_name, p_origin, 'pending')
  ON CONFLICT (run_id, class_name) DO UPDATE
  SET page_no = EXCLUDED.page_no,
      origin = COALESCE(stage1_classes.origin, EXCLUDED.origin);

END;
$$;

CREATE OR REPLACE FUNCTION stage1_mark_class_done(
  p_run_id TEXT,
  p_class_name TEXT,
  p_sink_count INTEGER,
  p_route_count INTEGER,
  p_auth_marker_count INTEGER,
  p_code_context_level TEXT DEFAULT NULL,
  p_errors JSONB DEFAULT '[]'::jsonb
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_class_name IS NULL OR length(trim(p_class_name)) = 0 THEN
    RAISE EXCEPTION 'class_name must not be empty';
  END IF;

  UPDATE stage1_classes
  SET status='done',
      done_at=now(),
      sink_count=GREATEST(COALESCE(p_sink_count,0),0),
      route_count=GREATEST(COALESCE(p_route_count,0),0),
      auth_marker_count=GREATEST(COALESCE(p_auth_marker_count,0),0),
      code_context_level=COALESCE(p_code_context_level, code_context_level),
      errors=COALESCE(p_errors,'[]'::jsonb)
  WHERE run_id=p_run_id AND class_name=p_class_name;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_insert_sink_json(
  p_run_id TEXT,
  p_worker_id TEXT,
  p_page_no INTEGER,
  p_sink JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_id BIGINT;
  v_class_name TEXT;
  v_method_name TEXT;
  v_sink_type TEXT;
  v_confidence TEXT;
  v_evidence JSONB;
BEGIN
  IF p_sink IS NULL THEN
    RAISE EXCEPTION 'sink payload is null';
  END IF;

  IF p_sink->>'record_type' IS DISTINCT FROM 'sink' THEN
    RAISE EXCEPTION 'sink.record_type must be sink';
  END IF;

  v_class_name := p_sink->>'class_name';
  v_method_name := p_sink->>'method_name';
  v_sink_type := p_sink->>'sink_type';
  v_confidence := p_sink->>'confidence';
  v_evidence := COALESCE(p_sink->'evidence','{}'::jsonb);

  IF v_class_name IS NULL OR length(trim(v_class_name)) = 0 THEN
    RAISE EXCEPTION 'sink.class_name must not be empty';
  END IF;
  IF v_method_name IS NULL OR length(trim(v_method_name)) = 0 THEN
    RAISE EXCEPTION 'sink.method_name must not be empty';
  END IF;
  IF v_sink_type IS NULL OR length(trim(v_sink_type)) = 0 THEN
    RAISE EXCEPTION 'sink.sink_type must not be empty';
  END IF;
  IF v_confidence IS NULL OR length(trim(v_confidence)) = 0 THEN
    RAISE EXCEPTION 'sink.confidence must not be empty';
  END IF;
  IF (v_evidence->>'reason') IS NULL OR length(trim(v_evidence->>'reason')) = 0 THEN
    RAISE EXCEPTION 'sink.evidence.reason must not be empty';
  END IF;

  INSERT INTO stage1_sinks(
    run_id, worker_id, page_no, class_name, method_name, method_descriptor,
    source_file, line_start, line_end, sink_type, framework, confidence, evidence
  )
  VALUES (
    p_run_id, p_worker_id, p_page_no, v_class_name, v_method_name, NULLIF(p_sink->>'method_descriptor',''),
    NULLIF(p_sink->>'source_file',''),
    NULLIF(p_sink->>'line_start','')::int,
    NULLIF(p_sink->>'line_end','')::int,
    v_sink_type,
    NULLIF(p_sink->>'framework',''),
    v_confidence,
    v_evidence
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_insert_route_json(
  p_run_id TEXT,
  p_worker_id TEXT,
  p_page_no INTEGER,
  p_route JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_id BIGINT;
  v_framework TEXT;
  v_http_method TEXT;
  v_path TEXT;
  v_class_name TEXT;
  v_evidence JSONB;
BEGIN
  IF p_route IS NULL THEN
    RAISE EXCEPTION 'route payload is null';
  END IF;

  IF p_route->>'record_type' IS DISTINCT FROM 'route' THEN
    RAISE EXCEPTION 'route.record_type must be route';
  END IF;

  v_framework := p_route->>'framework';
  v_http_method := p_route->>'http_method';
  v_path := p_route->>'path';
  v_class_name := p_route->>'class_name';
  v_evidence := COALESCE(p_route->'evidence','{}'::jsonb);

  IF v_framework IS NULL OR length(trim(v_framework)) = 0 THEN
    RAISE EXCEPTION 'route.framework must not be empty';
  END IF;
  IF v_http_method IS NULL OR length(trim(v_http_method)) = 0 THEN
    RAISE EXCEPTION 'route.http_method must not be empty';
  END IF;
  IF v_path IS NULL OR length(trim(v_path)) = 0 THEN
    RAISE EXCEPTION 'route.path must not be empty';
  END IF;
  IF v_class_name IS NULL OR length(trim(v_class_name)) = 0 THEN
    RAISE EXCEPTION 'route.class_name must not be empty';
  END IF;
  IF (v_evidence->>'reason') IS NULL OR length(trim(v_evidence->>'reason')) = 0 THEN
    RAISE EXCEPTION 'route.evidence.reason must not be empty';
  END IF;

  INSERT INTO stage1_routes(
    run_id, worker_id, page_no, framework, http_method, path,
    class_name, method_name, method_descriptor, source_file, line_start, line_end, evidence
  )
  VALUES (
    p_run_id, p_worker_id, p_page_no, v_framework, v_http_method, v_path,
    v_class_name,
    NULLIF(p_route->>'method_name',''),
    NULLIF(p_route->>'method_descriptor',''),
    NULLIF(p_route->>'source_file',''),
    NULLIF(p_route->>'line_start','')::int,
    NULLIF(p_route->>'line_end','')::int,
    v_evidence
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_insert_auth_marker_json(
  p_run_id TEXT,
  p_worker_id TEXT,
  p_page_no INTEGER,
  p_marker JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_id BIGINT;
  v_marker_type TEXT;
  v_framework TEXT;
  v_class_name TEXT;
  v_confidence TEXT;
  v_evidence JSONB;
BEGIN
  IF p_marker IS NULL THEN
    RAISE EXCEPTION 'auth_marker payload is null';
  END IF;

  IF p_marker->>'record_type' IS DISTINCT FROM 'auth_marker' THEN
    RAISE EXCEPTION 'auth_marker.record_type must be auth_marker';
  END IF;

  v_marker_type := p_marker->>'marker_type';
  v_framework := p_marker->>'framework';
  v_class_name := p_marker->>'class_name';
  v_confidence := p_marker->>'confidence';
  v_evidence := COALESCE(p_marker->'evidence','{}'::jsonb);

  IF v_marker_type IS NULL OR length(trim(v_marker_type)) = 0 THEN
    RAISE EXCEPTION 'auth_marker.marker_type must not be empty';
  END IF;
  IF v_framework IS NULL OR length(trim(v_framework)) = 0 THEN
    RAISE EXCEPTION 'auth_marker.framework must not be empty';
  END IF;
  IF v_class_name IS NULL OR length(trim(v_class_name)) = 0 THEN
    RAISE EXCEPTION 'auth_marker.class_name must not be empty';
  END IF;
  IF v_confidence IS NULL OR length(trim(v_confidence)) = 0 THEN
    RAISE EXCEPTION 'auth_marker.confidence must not be empty';
  END IF;
  IF (v_evidence->>'reason') IS NULL OR length(trim(v_evidence->>'reason')) = 0 THEN
    RAISE EXCEPTION 'auth_marker.evidence.reason must not be empty';
  END IF;

  INSERT INTO stage1_auth_markers(
    run_id, worker_id, page_no, marker_type, framework,
    class_name, method_name, method_descriptor, source_file, line_start, line_end,
    confidence, evidence
  )
  VALUES (
    p_run_id, p_worker_id, p_page_no, v_marker_type, v_framework,
    v_class_name,
    NULLIF(p_marker->>'method_name',''),
    NULLIF(p_marker->>'method_descriptor',''),
    NULLIF(p_marker->>'source_file',''),
    NULLIF(p_marker->>'line_start','')::int,
    NULLIF(p_marker->>'line_end','')::int,
    v_confidence,
    v_evidence
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
