---
name: java-stage1-coverage-worker
description: Java 阶段1「按页」审计 worker（独立版，Postgres 写入）。接收 page_no 后仅获取该页 class 清单，并逐类创建 subagent 调用 class-auditor：先 methods/fields 粗筛，再按需 get_method_by_name 拉少量方法源码；把 sinks/routes/auth_markers/warnings/classes/pages 状态全部写入 Postgres（javaAudit），并以数据库统计可验证完成数。禁止做项目级搜索或扩展扫描范围。
---

# Java 阶段1：按页扫描 Worker

你只负责“主编排器分配给你的这一页”。你必须逐类处理完毕，并通过 `done` 标记让完成数可验证。

## 输入

- `source_path`
- `output_path`
- `run_id`
- `worker_id`
- `page_no`
- `page_size`（默认 100）

## 禁止行为（本架构关键约束）

- 禁止对项目做关键字搜索/规则扫描/全局枚举未分配页
- 禁止对每个 class 默认 `get_class_source` 拉全类源码进上下文（成本过高）
- 只允许对本页 `get_all_classes` 返回的 class 清单逐类处理；源码获取必须由 class-auditor 采用“按需 get_method_by_name”的方式完成

## 输出（必须）

你必须把所有结果写入 Postgres（DB: javaAudit）：
- `stage1_classes`：本页 class 清单 + 每个 class 的 done 标记与计数
- `stage1_sinks` / `stage1_routes` / `stage1_auth_markers`：逐条 findings
- `stage1_warnings`：任何异常、schema 不合格记录、重试原因
- `stage1_pages`：更新该页的 expected/done 计数与状态

所有 SQL 均通过 Postgres MCP 的 `execute_sql` 执行，SQL 模板见主编排器：
- `references/POSTGRES_MCP_PLAYBOOK.md`

必须优先使用 DB 函数（减少推测与字段遗漏）：
- `stage1_upsert_class(...)`
- `stage1_log_warning(...)`
- `stage1_insert_sink_json(...)` / `stage1_insert_route_json(...)` / `stage1_insert_auth_marker_json(...)`
- `stage1_refresh_page_counts(...)`

写入映射（必须一致）：
- sink 记录写入 `stage1_sinks`：
  - `sink_type/framework/confidence/evidence` 直接映射
  - `line_start/line_end/method_descriptor/source_file` 不确定可为 null
- route 记录写入 `stage1_routes`：
  - `framework/http_method/path` 直接映射
  - `method_name/method_descriptor/source_file/line_start/line_end` 不确定可为 null
- auth_marker 记录写入 `stage1_auth_markers`：
  - `marker_type/framework/confidence/evidence` 直接映射
  - `method_name/method_descriptor/source_file/line_start/line_end` 不确定可为 null

## 必须流程

## subagent 并发限制（强制）

你最多只能同时运行 2 个 subagent。
- 禁止一次性启动大量 subagent 再等待
- 必须采用“小并发 + 及时回收 + 立即落库”的方式：拿到 subagent 结果就立刻写 DB 并标记该 class done

### Step 1：写入完整 class 清单（先做）（强制）

1) 调用 `get_all_classes(offset=page_no*page_size, count=page_size)`  
2) 将返回的 `items` 逐条 upsert 到 `stage1_classes`（status=pending）
3) 更新 `stage1_pages.expected_class_count`

要求：
- 禁止把 class 清单写入文件作为“状态真相”
- expected/done 必须以 DB 统计为准

### Step 2：逐类分析并追加 class_update

对每个 `class_name`：
1) 为该 class 创建一个 subagent 进行“三维审计”（强制）
   - subagent 必须使用技能：`/java-stage1-class-auditor`
   - subagent 的输入只包含：`class_name`、`page_no`
   - worker 自己禁止分析该 class（避免遗漏与上下文污染）
2) 严格处理 subagent 返回值（强制）
   - subagent 输出必须是一个 JSON 对象，且包含：
     - `code_context_level`: `members_only|method_source`
     - `sinks`: 数组（每个元素是完整 sinks.jsonl schema 的对象）
     - `routes`: 数组（每个元素是完整 routes.jsonl schema 的对象）
     - `auth_markers`: 数组（每个元素是完整 auth_markers.jsonl schema 的对象）
     - `errors`: 数组
3) 写入前做最小 schema 校验（强制）
   - sink：必须含 `record_type="sink"`、`sink_type`、`class_name`、`method_name`、`evidence.reason`、`confidence`、`page_no`
   - route：必须含 `record_type="route"`、`framework`、`http_method`、`path`、`class_name`、`evidence.reason`、`page_no`
   - auth_marker：必须含 `record_type="auth_marker"`、`marker_type`、`framework`、`class_name`、`evidence.reason`、`confidence`、`page_no`
   - 若某条记录不合格：不要写入该记录；把原因追加到本 class 的 `errors`，并写入一条 `stage1_warnings`
4) 将合格记录写入数据库（推荐使用 DB 写入函数）
   - sink：`SELECT stage1_insert_sink_json(run_id, worker_id, page_no, '{...}'::jsonb);`
   - route：`SELECT stage1_insert_route_json(run_id, worker_id, page_no, '{...}'::jsonb);`
   - auth_marker：`SELECT stage1_insert_auth_marker_json(run_id, worker_id, page_no, '{...}'::jsonb);`
5) 标记该 class 完成（写 DB）
   - `SELECT stage1_mark_class_done(run_id, class_name, sink_count, route_count, auth_marker_count, code_context_level, errors_jsonb);`
   - `SELECT stage1_refresh_page_counts(run_id, page_no);`

### Step 3：完成自检（强制）

用 DB 统计必须满足：
- `stage1_pages.done_class_count == stage1_pages.expected_class_count`

不满足时：
1) 写入 `stage1_warnings`
2) 继续补齐遗漏直到满足

### Step 4：写入 worker_summary.json 并汇报

worker 汇报给主编排器的结构化信息需包含：
- `page_no`
- `expected_class_count`
- `done_class_count`
- `new_sink_count` / `new_route_count` / `new_auth_marker_count`
- `error_count`

将 summary 的关键信息以 JSON 结构发送给主编排器（字段见其 `references/WORKER_PROTOCOL.md`）。
