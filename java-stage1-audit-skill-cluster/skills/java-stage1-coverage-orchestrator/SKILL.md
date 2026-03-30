---
name: java-stage1-coverage-orchestrator
description: Java 阶段1全覆盖审计编排器。先读 references/TEAMMATE_EXECUTION.md，再用 TeamCreate + teammate + SendMessage 非阻塞调度 /java-stage1-coverage-worker，禁止同步 subagent 跑 worker。worker 会为每页启动 route/auth/sink 3 个维度 subagent；所有状态与覆盖率以 Postgres（javaAudit）SQL 为准。用户提到启动、继续、调度或查看 Stage1 审计进度时必须使用。
---

# Java 阶段1：100% 覆盖审计（主编排器）

阶段1目标：
- 全量 sink 点（方法级）
- 全量路由映射（接口→类→方法级）
- 鉴权相关标记（Filter/Interceptor/Aspect/注解/配置等，仅标记相关性）

本编排器只负责“分发与覆盖率闭环”，不做具体代码识别。

## 前置要求

- 已开启 Claude Code agent teams：`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- 已配置并可调用 `jadx-ai-mcp`：
  - `get_all_classes(offset, count)`
  - `get_methods_of_class(class_name)`
  - `get_fields_of_class(class_name)`
  - `get_method_by_name(class_name, method_name)`
- 已配置 Postgres MCP 并连接本地 `javaAudit` 数据库（至少支持 `execute_sql`）

## 输入

用户提供：
- `source_path`
- `output_path`（默认 `{source_path}_audit`）
- 可选：`page_size`（默认 100）、`concurrency`（默认 4）
- `run_id`（可选；不提供则用时间戳生成，必须全局唯一）

## 数据库协议（必须遵守）

## 执行前检查（强制）

开始任何调度前，你必须先完成以下检查：
1) 先读取 `references/TEAMMATE_EXECUTION.md`
2) 明确将“agent team”理解为“Team/Teammate 模式”，并且必须使用：
   - TeamCreate
   - 创建/复用 teammate（worker）
   - SendMessage 下发页任务
3) 禁止把 worker 当作 subagent 同步执行（会阻塞主会话）

在开始前必须阅读：
- `references/WORKER_PROTOCOL.md`
- `references/POSTGRES_MCP_PLAYBOOK.md`
- `references/TEAMMATE_EXECUTION.md`
- `references/MISUSE_DETECTOR.md`

## 主编排器执行步骤（必须）

## 编排约束（强制）

1) 只允许“动态按页调度”
- 任何 worker 任务只能包含单个 `page_no`
- 禁止把页范围（例如 0-274）一次性分配给某个 worker
- worker 完成一页就结束；主编排器负责再分配下一页

1.1) 主编排器必须创建 teammate 运行 worker
- 禁止主编排器在自身上下文中执行 worker 的审计逻辑（否则主编排器会“变成 worker”，并引发遗漏与进度错觉）
- 每一页必须由一个独立 teammate 执行 `/java-stage1-coverage-worker`
- 主编排器只做：领取页 → 创建/复用 teammate → SendMessage 下发参数 → 轮询 DB → 决策重试/继续
- 主会话必须保持可交互：worker 运行期间若用户询问进度，应立即用 DB 查询回答（可调用 `java-stage1-status-checker`）

1.2) 误用检测（强制）
- 如果你发现自己正准备“直接调用 worker skill”或“以 subagent 同步执行 worker”，必须立刻停止并按 `references/MISUSE_DETECTOR.md` 输出纠错提示

2) 禁止用删除本地会话目录来“停止 team”
- 禁止删除 `~/.claude/teams` 或 `~/.claude/tasks` 来试图重建 team
- 若需要终止当前 team，应使用 Claude Code 的 Team/Task 生命周期接口正常结束（例如 TeamDelete），再创建新 team

3) 数据库是唯一状态来源
- 覆盖率、未完成页、重试页只以 SQL 查询结果判定（见 `references/POSTGRES_MCP_PLAYBOOK.md`）

### 1) 初始化数据库（建表 + 创建 run + 初始化 pages）

1) 若表不存在：执行 `java-stage1-audit-skill-cluster/db/ddl.sql`（一次性建表）
2) 调用 `get_all_classes(offset=0,count=page_size)` 获取 `total_classes`
3) 计算 `total_pages = ceil(total_classes / page_size)`
4) 写入 `stage1_runs`（run_id/source_path/output_path/page_size/total_classes/total_pages）
5) 批量初始化 `stage1_pages`（0..total_pages-1，status=pending）

以上所有操作必须通过 Postgres MCP 的 `execute_sql` 完成，SQL 模板见 `references/POSTGRES_MCP_PLAYBOOK.md`。

### 2) 动态按页调度 worker（直到覆盖率 100%）

并发上限：`concurrency`。

调度规则：
- 只从 `stage1_pages.status IN ('pending','needs_retry')` 选择页分配给空闲 worker
- 必须使用“原子领取”SQL（`FOR UPDATE SKIP LOCKED`），确保不会重复分配（SQL 见 playbook）
- 每个 worker 只处理一个 `page_no`，完成后立即退出；主编排器再分配新页给新的/空闲 worker
- 主编排器不得阻塞等待某个 worker 完成；必须边调度边轮询 DB，并随时响应用户

worker 必须使用技能：
- `/java-stage1-coverage-worker`

分配给 worker 的任务内容必须包含：
- `source_path`、`output_path`、`page_no`、`page_size`
- 严格遵守 `references/WORKER_PROTOCOL.md` 的“只看让他看的内容，不做全局搜索”
- 必须写入 DB：`run_id`、`worker_id`（主编排器分配给每个 worker 的唯一标识）
- 明确要求 worker：只启动 3 个维度 subagent，分别负责 route/auth/sink，对整页类列表做分维度审计（见 worker skill）
- 明确要求 worker：不得回退到 `/java-stage1-class-auditor` 的逐类三维聚合路径
- 明确要求 worker：页任务结束后丢弃上一页上下文，再等待下一次任务

### 3) 接收 worker 回报并更新 DB 状态

worker 完成后会给出结构化回报（JSON）。你必须：
- 将该页 `stage1_pages.status` 更新为 `done`，并写入新增记录数、错误数
- 若 DB 中 `done_class_count < expected_class_count`：将该页标记为 `needs_retry` 并重新调度

同时做输出质量门禁（强制，以 DB 为准）：
- 若发现记录 schema 违例（缺字段、枚举非法、字段名错误等），必须写入 `stage1_warnings`
- 对 schema 违例较多的页，将页置为 `needs_retry` 并重跑

### 4) 完成判定（唯一标准）

阶段1完成当且仅当：
- 对所有页：DB 中 `done_class_count == expected_class_count`
- 覆盖率（DB 聚合）= 100%
- 不存在非 done 的页

覆盖率查询与未完成页排查 SQL 见 `references/POSTGRES_MCP_PLAYBOOK.md`。
