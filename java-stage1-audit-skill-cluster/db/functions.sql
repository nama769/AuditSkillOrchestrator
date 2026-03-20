-- Stage1 DB helper functions (PostgreSQL)
-- DB: javaAudit
-- Schema: public

CREATE OR REPLACE FUNCTION stage1_pick_page(p_run_id TEXT, p_worker_id TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_page_no INTEGER;
BEGIN
  WITH picked AS (
    SELECT run_id, page_no
    FROM stage1_pages
    WHERE run_id = p_run_id
      AND status IN ('pending', 'needs_retry')
    ORDER BY page_no
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  UPDATE stage1_pages p
  SET status = 'in_progress',
      assigned_to = p_worker_id,
      assigned_at = now()
  FROM picked
  WHERE p.run_id = picked.run_id AND p.page_no = picked.page_no
  RETURNING p.page_no INTO v_page_no;

  RETURN v_page_no;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_refresh_page_counts(p_run_id TEXT, p_page_no INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE stage1_pages
  SET expected_class_count = (
        SELECT COUNT(*) FROM stage1_classes
        WHERE run_id = p_run_id AND page_no = p_page_no
      ),
      done_class_count = (
        SELECT COUNT(*) FROM stage1_classes
        WHERE run_id = p_run_id AND page_no = p_page_no AND status = 'done'
      )
  WHERE run_id = p_run_id AND page_no = p_page_no;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_mark_page_done(
  p_run_id TEXT,
  p_page_no INTEGER,
  p_new_sink_count INTEGER,
  p_new_route_count INTEGER,
  p_new_auth_marker_count INTEGER,
  p_error_count INTEGER,
  p_last_error TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM stage1_refresh_page_counts(p_run_id, p_page_no);

  UPDATE stage1_pages
  SET status = 'done',
      new_sink_count = COALESCE(p_new_sink_count, 0),
      new_route_count = COALESCE(p_new_route_count, 0),
      new_auth_marker_count = COALESCE(p_new_auth_marker_count, 0),
      error_count = COALESCE(p_error_count, 0),
      last_error = p_last_error
  WHERE run_id = p_run_id AND page_no = p_page_no;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_mark_page_needs_retry(
  p_run_id TEXT,
  p_page_no INTEGER,
  p_last_error TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE stage1_pages
  SET status = 'needs_retry',
      last_error = p_last_error
  WHERE run_id = p_run_id AND page_no = p_page_no;
END;
$$;

CREATE OR REPLACE FUNCTION stage1_run_progress(p_run_id TEXT)
RETURNS TABLE(
  done BIGINT,
  expected BIGINT,
  percent NUMERIC(6,2),
  pending_pages BIGINT,
  in_progress_pages BIGINT,
  needs_retry_pages BIGINT,
  done_pages BIGINT
)
LANGUAGE sql
AS $$
  WITH agg AS (
    SELECT
      COALESCE(SUM(done_class_count),0) AS done,
      COALESCE(SUM(expected_class_count),0) AS expected
    FROM stage1_pages
    WHERE run_id = p_run_id
  ),
  st AS (
    SELECT
      COUNT(*) FILTER (WHERE status='pending') AS pending_pages,
      COUNT(*) FILTER (WHERE status='in_progress') AS in_progress_pages,
      COUNT(*) FILTER (WHERE status='needs_retry') AS needs_retry_pages,
      COUNT(*) FILTER (WHERE status='done') AS done_pages
    FROM stage1_pages
    WHERE run_id = p_run_id
  )
  SELECT
    agg.done,
    agg.expected,
    CASE WHEN agg.expected = 0 THEN 0 ELSE ROUND((agg.done::numeric * 100.0) / agg.expected::numeric, 2) END AS percent,
    st.pending_pages,
    st.in_progress_pages,
    st.needs_retry_pages,
    st.done_pages
  FROM agg, st;
$$;

