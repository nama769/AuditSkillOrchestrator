---
title: Stage1 Worker 协作协议
---

# 阶段1 Worker 协作协议（按页分发）

目标：确保“按页分配 → worker 逐类分析 → done 标记可验证 → 主编排器汇总覆盖率”可闭环运行。

## Worker 输入

主编排器只传递：
- `source_path`
- `output_path`
- `run_id`
- `worker_id`
- `page_no`
- `page_size`

## Worker 禁止行为（本架构关键约束）

worker 只能分析“主编排器明确让你看的内容”：
- 允许：把本页类列表交给 3 个维度 subagent；每个 subagent 只负责一个维度，并先枚举 methods/fields，再按需 `get_method_by_name` 获取少量方法源码做判断
- 禁止：对项目做关键字搜索、全局 grep、按规则扫描未分配的类、向外扩展分析范围

你只对“被分配到的类及其按需拉取的局部方法源码内容”做判定并输出证据即可。

## Worker 必须使用 3 个维度 subagent（强制）

worker 必须只创建以下 3 个 subagent：
- route subagent：只使用技能 `/java-stage1-route-extractor`
- auth subagent：只使用技能 `/java-stage1-auth-marker`
- sink subagent：只使用技能 `/java-stage1-sink-extractor`

3 个 subagent 都处理同一份 `class_names[]`，并按类返回结果：
- 先看类名、方法名、字段名/类型
- 仅在当前维度可能相关时按需 `get_method_by_name`
- 对每个 class 返回 `code_context_level/records/errors`

worker 自己不得直接做 route/auth/sink 识别，也不得回退到 `/java-stage1-class-auditor` 的逐类聚合路径。

并发限制（强制）：
- worker 必须只运行这 3 个 subagent
- 禁止按 class 批量发射大量 subagent
- 禁止在维度 subagent 内继续派生新的审计 subagent

## Worker 必须写入数据库（强制）

所有状态与记录必须通过 Postgres MCP `execute_sql` 写入：
- `stage1_classes`：本页类列表与每个 class 的完成标记
- `stage1_sinks` / `stage1_routes` / `stage1_auth_markers`：逐条 findings
- `stage1_warnings`：告警/异常/不合格记录原因
- `stage1_pages`：更新 expected/done/计数与最终 status

## 完成定义（强制）

完成数必须以 DB 为准，并满足：
- `stage1_pages.done_class_count == stage1_pages.expected_class_count`

类级 done 标记必须在该类的 route/auth/sink 三路结果全部汇总后再写入。

不满足时必须：
1) 在 `stage1_warnings` 写告警（含缺口与原因）
2) 继续补齐遗漏，直到满足完成定义

## Worker 结束汇报（发给主编排器）

```json
{
  "page_no": 3,
  "expected_class_count": 100,
  "done_class_count": 100,
  "new_sink_count": 12,
  "new_route_count": 8,
  "new_auth_marker_count": 5,
  "error_count": 0,
  "db": {
    "tables": ["stage1_pages","stage1_classes","stage1_sinks","stage1_routes","stage1_auth_markers","stage1_warnings"]
  }
}
```

回报后立即结束当前页任务，并丢弃上一页的类列表、源码片段、计数与错误上下文。若 teammate 被复用，只能基于新的页任务重新开始。
