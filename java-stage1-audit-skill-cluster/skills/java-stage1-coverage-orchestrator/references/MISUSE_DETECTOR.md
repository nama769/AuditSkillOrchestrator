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

## 错误模式 2：一次性发射大量 subagent

症状：
- worker 一次性启动大量 subagent（例如 100 个）后等待
- 出现 “No task found with ID …” 或无法收集返回值

纠错提示：
- “检测到批量发射 subagent。必须将 subagent 并发限制为 2，并采用小并发、及时回收、结果到手立即落库的模式。”

## 错误模式 3：未先写 class 清单

症状：
- `stage1_pages.expected_class_count` 长时间为 NULL
- `stage1_classes` 该页无记录

纠错提示：
- “检测到未执行 Step 1（写入 class 清单）。必须先 upsert stage1_classes 并更新 expected_class_count，再进入单类审计。”

