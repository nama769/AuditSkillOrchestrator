---
title: Postgres MCP 操作手册（Stage1）
---

# Postgres MCP 操作手册（Stage1）

目标：把阶段1所有“记录/状态/覆盖率校验”统一迁移到 Postgres（DB: `javaAudit`），并通过 Postgres MCP 的 `execute_sql` 完成所有写入与查询。

本手册只使用你提供的工具集：
- `execute_sql`：执行 SQL（包含 DDL/DML/查询）
- `list_schemas` / `list_objects` / `get_object_details`：可选，用于自检表结构

## 工具调用格式（Claude Code）

你在 Claude Code 的工具面板里看到的工具名就是：`execute_sql` / `list_schemas` / `list_objects` 等。

本手册里每段 SQL 的执行方式都是：
- 选择工具：`execute_sql`
- 参数：传入一段 SQL 字符串

不同 Postgres MCP 实现对参数名可能略有差异，常见是以下两种之一（按你的工具面板字段名为准）：

**形式 A（常见）：**
```json
{"sql":"SELECT 1;"}
```

**形式 B（也常见）：**
```json
{"query":"SELECT 1;"}
```

如果你不确定字段名：
- 先点开工具 `execute_sql` 的参数输入框，看它要求的是 `sql` 还是 `query`
- 然后把本手册中的 SQL 原样粘贴进去即可

## 0) 一次性建表（第一次运行必须做）

将 `java-stage1-audit-skill-cluster/db/ddl.sql` 的内容复制到一次 `execute_sql` 中执行。

## 0.0) 迁移：为已有表补充约束（推荐）

如果你之前已经建过表，建议再执行一次迁移脚本，为关键枚举字段加 CHECK 约束并做最小归一化（例如将 pages.status 的 `completed` 统一为 `done`）：
- `db/migrations/001_add_constraints.sql`
- `db/migrations/002_add_class_code_context_level.sql`

## 0.1) 可选：安装固定流程脚本（强烈推荐）

为了减少主 agent/worker 对“该用哪条 SQL”的推测，把固定操作收敛为 DB 内置函数/视图：
- `db/functions.sql`：领取任务、刷新页计数、标记页完成、计算覆盖率
- `db/functions_write.sql`：写入 class/warning/sink/route/auth_marker（带最小字段校验）
- `db/views.sql`：常用只读视图

安装方式：把两个文件内容各自复制到一次 `execute_sql` 执行即可。

安装后建议优先使用函数，而不是手写 SQL：
- 领取页：`SELECT stage1_pick_page('{run_id}','{worker_id}');`
- 覆盖率：`SELECT * FROM stage1_run_progress('{run_id}');`
 - 写 warning：`SELECT stage1_log_warning('{run_id}','warning','{worker_id}',{page_no},NULL,'msg','{}'::jsonb);`
 - 写 findings：`SELECT stage1_insert_sink_json('{run_id}','{worker_id}',{page_no}, '{...}'::jsonb);`（route/auth_marker 同理）

worker 建议写入策略（减少推测）：
- 不再把一个类拆成 3 次分析调用；改为 worker 为每个 class 创建一个 subagent 执行 `/java-stage1-class-auditor`，一次性返回三类记录
- worker 只负责：schema 校验 → 调用 `stage1_insert_*_json` 落库 → 调用 `stage1_mark_class_done(run_id, class_name, sink_count, route_count, auth_marker_count, code_context_level, errors_jsonb)` + `stage1_refresh_page_counts`

## 1) 创建一次 stage1 run（主编排器）

### 1.1 插入 run 元信息

执行：
```sql
INSERT INTO stage1_runs(run_id, source_path, output_path, page_size, total_classes, total_pages, status)
VALUES ('{run_id}', '{source_path}', '{output_path}', {page_size}, {total_classes}, {total_pages}, 'running')
ON CONFLICT (run_id) DO NOTHING;
```

### 1.2 初始化 pages（0..total_pages-1）

执行：
```sql
INSERT INTO stage1_pages(run_id, page_no, status)
SELECT '{run_id}', gs, 'pending'
FROM generate_series(0, {total_pages}-1) AS gs
ON CONFLICT (run_id, page_no) DO NOTHING;
```

## 2) 原子领取一页任务（主编排器）

主编排器循环调用，拿到一个 `page_no` 就分配给一个 worker。

执行（单条 SQL，原子）：
```sql
WITH picked AS (
  SELECT run_id, page_no
  FROM stage1_pages
  WHERE run_id = '{run_id}'
    AND status IN ('pending', 'needs_retry')
  ORDER BY page_no
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE stage1_pages p
SET status = 'in_progress',
    assigned_to = '{worker_id}',
    assigned_at = now()
FROM picked
WHERE p.run_id = picked.run_id AND p.page_no = picked.page_no
RETURNING p.page_no;
```

返回为空表示没有可领取的页（可能已全部 done，或仍有 in_progress 的 worker 未完成）。

## 3) worker 写入 class 清单（替代 class_list.jsonl）

worker 在拿到 `page_no` 后，先调用 `get_all_classes(offset=page_no*page_size,count=page_size)` 得到 items（class_name 列表）。

对每个 class 逐条插入（简单但可靠）：
```sql
INSERT INTO stage1_classes(run_id, page_no, class_name, origin, status)
VALUES ('{run_id}', {page_no}, '{class_name}', '{origin}', 'pending')
ON CONFLICT (run_id, class_name) DO UPDATE
SET page_no = EXCLUDED.page_no,
    origin = COALESCE(stage1_classes.origin, EXCLUDED.origin);
```

写完后，更新该页 expected_class_count：
```sql
UPDATE stage1_pages
SET expected_class_count = (
  SELECT COUNT(*) FROM stage1_classes WHERE run_id='{run_id}' AND page_no={page_no}
)
WHERE run_id='{run_id}' AND page_no={page_no};
```

## 4) worker 写入 findings（三张表）

### 4.1 写入 warning（任何时候都可以）

```sql
INSERT INTO stage1_warnings(run_id, level, worker_id, page_no, class_name, message, details)
VALUES (
  '{run_id}',
  '{level}',
  '{worker_id}',
  {page_no},
  {class_name_nullable},
  '{message}',
  '{details_json}'::jsonb
);
```

### 4.2 写入 sink

把 sink-extractor 的每条记录映射为一行：
```sql
INSERT INTO stage1_sinks(
  run_id, worker_id, page_no, class_name, method_name, method_descriptor,
  source_file, line_start, line_end, sink_type, framework, confidence, evidence
) VALUES (
  '{run_id}', '{worker_id}', {page_no}, '{class_name}', '{method_name}', {method_descriptor_nullable},
  {source_file_nullable}, {line_start_nullable}, {line_end_nullable}, '{sink_type}', {framework_nullable},
  '{confidence}', '{evidence_json}'::jsonb
);
```

### 4.3 写入 route

```sql
INSERT INTO stage1_routes(
  run_id, worker_id, page_no, framework, http_method, path,
  class_name, method_name, method_descriptor, source_file, line_start, line_end, evidence
) VALUES (
  '{run_id}', '{worker_id}', {page_no}, '{framework}', '{http_method}', '{path}',
  '{class_name}', {method_name_nullable}, {method_descriptor_nullable}, {source_file_nullable},
  {line_start_nullable}, {line_end_nullable}, '{evidence_json}'::jsonb
);
```

### 4.4 写入 auth_marker

```sql
INSERT INTO stage1_auth_markers(
  run_id, worker_id, page_no, marker_type, framework,
  class_name, method_name, method_descriptor, source_file, line_start, line_end,
  confidence, evidence
) VALUES (
  '{run_id}', '{worker_id}', {page_no}, '{marker_type}', '{framework}',
  '{class_name}', {method_name_nullable}, {method_descriptor_nullable}, {source_file_nullable},
  {line_start_nullable}, {line_end_nullable}, '{confidence}', '{evidence_json}'::jsonb
);
```

## 5) worker 标记 class 完成 + 更新页计数

每处理完一个 class 后更新：
```sql
UPDATE stage1_classes
SET status='done',
    done_at=now(),
    sink_count={sink_count},
    route_count={route_count},
    auth_marker_count={auth_marker_count},
    errors='{errors_json}'::jsonb
WHERE run_id='{run_id}' AND class_name='{class_name}';
```

页级 done_class_count 用 DB 统计（避免自己算错）：
```sql
UPDATE stage1_pages
SET done_class_count = (
  SELECT COUNT(*) FROM stage1_classes WHERE run_id='{run_id}' AND page_no={page_no} AND status='done'
)
WHERE run_id='{run_id}' AND page_no={page_no};
```

worker 完成页后，把页状态置为 done（主编排器也可以在收到回报后执行）：
```sql
UPDATE stage1_pages
SET status='done',
    new_sink_count={new_sink_count},
    new_route_count={new_route_count},
    new_auth_marker_count={new_auth_marker_count},
    error_count={error_count},
    last_error=NULL
WHERE run_id='{run_id}' AND page_no={page_no};
```

## 6) 覆盖率与完成判定（主编排器）

### 6.1 覆盖率

```sql
SELECT
  COALESCE(SUM(done_class_count),0) AS done,
  COALESCE(SUM(expected_class_count),0) AS expected
FROM stage1_pages
WHERE run_id='{run_id}';
```

覆盖率 100% 的判定（强制）：
- `done == expected`
- 且不存在 `status IN ('pending','in_progress','needs_retry')` 的页

### 6.2 找出未完成页

```sql
SELECT page_no, status, expected_class_count, done_class_count, assigned_to
FROM stage1_pages
WHERE run_id='{run_id}' AND status <> 'done'
ORDER BY page_no;
```

### 6.3 找出“页完成但 class 未完成”的异常（一致性校验）

```sql
SELECT p.page_no, p.expected_class_count, p.done_class_count
FROM stage1_pages p
WHERE p.run_id='{run_id}'
  AND p.status='done'
  AND (p.expected_class_count IS DISTINCT FROM p.done_class_count);
```
