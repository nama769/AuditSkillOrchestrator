---
name: java-stage1-status-checker
description: Java Stage1 审计状态检测器。用户询问当前进度、覆盖率、卡点、未完成页、告警或如何继续审计时，或主 agent 需要在启动前与运行中恢复现场时，必须使用本技能从 Postgres（javaAudit）查询 stage1_runs/pages/classes/warnings/sinks/routes/auth_markers，并输出进度报告与下一步建议。
---

# Stage1 状态检测（Postgres）

你是主 agent 的状态探针。你只读数据库，不修改任何表，不调度 worker，不推测未查询到的数据。

## 输入

用户可能提供：
- `run_id`（可选）

如果未提供 `run_id`：
- 先列出最近 5 条 run（按 created_at 倒序），让用户选择；或直接选最新一条并在报告中说明“默认选择最新 run”。

## 数据源

使用 Postgres MCP 的 `execute_sql` 查询（只读）。

表：
- `stage1_runs`
- `stage1_pages`
- `stage1_classes`
- `stage1_warnings`
- `stage1_sinks`
- `stage1_routes`
- `stage1_auth_markers`

## 必须输出

输出一个 Markdown 报告，包含以下小节（顺序固定）：

1) Run 概览  
- run_id / status / created_at / source_path / output_path / page_size / total_pages / total_classes

2) 覆盖率  
- done / expected / 覆盖率百分比
- 页状态计数（pending/in_progress/done/needs_retry）

3) 卡点诊断（强制给结论）  
- 如果存在 in_progress 超过 20 分钟的页：列出前 20 条，包含 page_no/assigned_to/assigned_at/expected/done
- 如果存在 needs_retry：列出前 20 条与 last_error
- 如果 expected_class_count 为 null 的页很多：提示这些页可能尚未被 worker 领取，或尚未完成 Step 1 的类列表入库

4) Worker 统计（可用于判断是否有 worker 挂死或过慢）  
- 近 60 分钟内按 assigned_to 汇总：in_progress 页数 / done 页数

5) 最近告警  
- 最近 50 条 warnings（time/level/worker_id/page_no/class_name/message）
- 按 message 前缀或 details->>'type'（若存在）做 Top 10 聚合（可选）

6) 下一步建议（必须可执行）  
- 给出 3-5 条建议，必须基于本次查询结果，例如：
  - “重跑 needs_retry 的页”
  - “回收长期 in_progress 的页（置为 needs_retry）” （只提出建议，不在本技能执行更新）
  - “提升并发度/缩小 page_size”

## SQL 模板

SQL 模板见：
- `references/QUERIES.md`
