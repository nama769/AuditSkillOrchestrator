---
title: 错误模式检测与纠错提示
---

# 错误模式检测与纠错提示

目的：减少“把 Team/Teammate 当成 subagent”的误用，避免主会话阻塞与进度错觉。

## 错误模式 1：主编排器直接执行 worker

症状：
- 主编排器在自己的上下文中直接运行 `/java-stage1-coverage-worker`
- 用户在 worker 工作期间无法与主编排器交互（会话阻塞）

纠错提示（主编排器必须输出并停止当前错误路径）：
- “检测到你正试图在主会话中执行 worker。必须改为 Team/Teammate 模式：TeamCreate → 创建 teammate → SendMessage 下发 page 任务。详见 TEAMMATE_EXECUTION.md。”

## 错误模式 2：worker 未按三维拆分执行

症状：
- worker 继续按 class 批量启动大量 subagent
- worker 只起 1 个混合 subagent，或继续走 `/java-stage1-class-auditor`
- 维度 subagent 内再次派生审计 subagent

纠错提示：
- “检测到 worker 未按 route/auth/sink 三维拆分执行。必须只启动 3 个维度 subagent，每个 subagent 只负责一个维度、处理整页类列表，并在 worker 侧汇总后统一落库。”

## 错误模式 3：未先写入类列表

症状：
- `stage1_pages.expected_class_count` 长时间为 NULL
- `stage1_classes` 该页无记录

纠错提示：
- “检测到未执行 Step 1。必须先 upsert stage1_classes 并更新 expected_class_count，再进入 route/auth/sink 三路维度审计。”
