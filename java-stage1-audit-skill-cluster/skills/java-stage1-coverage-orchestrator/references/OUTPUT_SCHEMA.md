---
title: Stage1 JSONL 输出协议
---

# 阶段1 JSONL 输出协议（固定格式）

说明：当前阶段1推荐使用 Postgres（javaAudit）作为唯一状态后端，避免 JSONL 作为状态机导致的并发与一致性问题。
- 本文件保留为“记录结构定义”（sinks/routes/auth_markers 的字段与枚举依然适用）
- 状态/覆盖率/告警/任务领取请以 `POSTGRES_MCP_PLAYBOOK.md` 与数据库表为准

本协议用于阶段1“100% 覆盖的全量扫描”：按类/方法粒度输出 sink、路由、鉴权相关标记，并提供可验证的覆盖率与进度文件。

## 输出目录结构（必须）

`{output_path}/stage1/`
- `meta.json`：本轮扫描元信息
- `progress.jsonl`：主编排器维护的页级进度
- `warnings.jsonl`：遗漏/异常/重试等告警
- `pages/`
  - `page-{page_no}/`
    - `class_list.jsonl`：该页 class 清单（逐行打完成标记）
    - `sinks.jsonl`：该页所有 sink 记录
    - `routes.jsonl`：该页所有路由记录
    - `auth_markers.jsonl`：该页所有鉴权相关标记记录
    - `worker_summary.json`：该页统计（类数、记录数、错误数）
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
- `done_class_count`：整数（必须由 `class_list.jsonl` 的 done 统计得出）
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

## class_list.jsonl（类清单与完成标记，JSONL）

两类记录：

### 1) 初始清单行（必须先写）

字段：
- `record_type`：固定 `class_item`
- `page_no`：整数
- `index_in_page`：整数
- `class_name`：字符串
- `origin`：`source` | `jar` | `class` | `unknown`
- `done`：布尔（初始为 false）

### 2) 追加更新行（推荐）

字段：
- `record_type`：固定 `class_update`
- `page_no`：整数
- `class_name`：字符串
- `done`：布尔（完成时 true）
- `done_at`：ISO8601 或 null
- `sink_count` / `route_count` / `auth_marker_count`：整数
- `errors`：字符串数组

统计规则：对初始清单的每个 `class_name`，以最后一条 `class_update` 为准。

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
