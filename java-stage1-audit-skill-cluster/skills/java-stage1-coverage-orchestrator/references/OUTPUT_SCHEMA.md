---
title: Stage1 JSONL 输出协议
---

# 阶段1 记录结构参考

说明：Stage1 以 Postgres（javaAudit）为唯一状态后端，状态、覆盖率、告警与任务领取都以数据库和 `POSTGRES_MCP_PLAYBOOK.md` 为准。
- 本文件只保留导出格式参考
- sinks/routes/auth_markers 的字段与枚举定义仍适用

本参考用于阶段1全量扫描的可选导出：按类/方法粒度输出 sink、路由与鉴权相关标记。

## 输出目录结构（可选）

`{output_path}/stage1/`
- `meta.json`：本轮扫描元信息
- `progress.jsonl`：按 DB 聚合结果导出的页级进度
- `warnings.jsonl`：从 DB 导出的告警副本
- `pages/`
  - `page-{page_no}/`
    - `class_list.jsonl`：该页类列表导出
    - `sinks.jsonl`：该页所有 sink 记录
    - `routes.jsonl`：该页所有路由记录
    - `auth_markers.jsonl`：该页所有鉴权相关标记记录
    - `worker_summary.json`：该页摘要
- `merged/`（可选）
  - `sinks.jsonl` / `routes.jsonl` / `auth_markers.jsonl`
  - `stage1_summary.json`

## meta.json（单个 JSON）

字段：
- `run_id`：字符串，唯一标识本次运行
- `created_at`：ISO8601 时间
- `tooling`：对象（可选）
- `page_size`：整数，默认 100
- `total_classes_estimate`：整数或 null

## progress.jsonl（页级进度，JSONL）

一页一行。字段：
- `page_no`：整数，从 0 开始
- `page_size`：整数
- `assigned_to`：字符串
- `assigned_at`：ISO8601
- `status`：`pending` | `in_progress` | `done` | `needs_retry`
- `expected_class_count`：整数
- `done_class_count`：整数
- `new_sink_count` / `new_route_count` / `new_auth_marker_count`：整数（可选）
- `error_count`：整数（可选）
- `evidence`：对象（输出文件路径）

## warnings.jsonl（告警，JSONL）

一条告警一行：
- `time`：ISO8601
- `level`：`warning` | `error`
- `page_no`：整数或 null
- `class_name`：字符串或 null
- `message`：字符串
- `details`：对象（可选）

## class_list.jsonl（类列表导出，JSONL）

推荐使用单条 `class_item` 记录表示该页类列表：

字段：
- `record_type`：固定 `class_item`
- `page_no`：整数
- `index_in_page`：整数
- `class_name`：字符串
- `origin`：`source` | `jar` | `class` | `unknown`
- `done`：布尔（初始为 false）

## sinks.jsonl（方法级敏感点，JSONL）

一条记录一行：
- `record_type`：固定 `sink`
- `sink_type`：`sql`/`cmd_exec`/`ssrf`/`file_read`/`file_write`/`deserialize`/`xxe`/`template`/`spel`/`ognl`/`jndi`/`ldap`/`runtime_reflect`/`response_write`/`redirect`/`xpath`/`other`
- `framework`：字符串或 null
- `class_name`：字符串
- `method_name`：字符串
- `method_descriptor`：字符串或 null
- `source_file`：字符串或 null
- `line_start` / `line_end`：整数或 null
- `evidence`：对象（必须含 `reason`，建议含 `api`、`snippet`）
- `confidence`：`high` | `medium` | `low`
- `page_no`：整数

## routes.jsonl（路由映射，JSONL）

- `record_type`：固定 `route`
- `framework`：`spring_mvc` | `jax_rs` | `servlet` | `struts2` | `webservice` | `other`
- `http_method`：`GET`/`POST`/`PUT`/`DELETE`/`PATCH`/`OPTIONS`/`HEAD`/`*`
- `path`：字符串（未知用 `(unknown)`）
- `class_name`：字符串
- `method_name`：字符串或 null
- `method_descriptor`：字符串或 null
- `source_file`：字符串或 null
- `line_start` / `line_end`：整数或 null
- `evidence`：对象（必须含 `reason`）
- `page_no`：整数

## auth_markers.jsonl（鉴权相关标记，JSONL）

- `record_type`：固定 `auth_marker`
- `marker_type`：`filter` | `interceptor` | `aspect` | `annotation` | `config` | `middleware` | `session` | `token` | `rbac` | `acl` | `other`
- `framework`：`spring_security` | `shiro` | `jwt` | `custom` | `unknown`
- `class_name`：字符串
- `method_name`：字符串或 null
- `method_descriptor`：字符串或 null
- `source_file`：字符串或 null
- `line_start` / `line_end`：整数或 null
- `evidence`：对象（必须含 `reason`）
- `confidence`：`high` | `medium` | `low`
- `page_no`：整数
