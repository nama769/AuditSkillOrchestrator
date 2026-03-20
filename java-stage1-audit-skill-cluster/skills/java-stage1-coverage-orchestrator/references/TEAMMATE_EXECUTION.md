---
title: Team/Teammate 调度规范（避免阻塞）
---

# Team/Teammate 调度规范（避免主会话阻塞）

目标：确保主编排器在 worker 工作时仍可响应用户；worker 必须作为独立 teammate 运行，而不是在主编排器上下文中同步执行。

## 核心规则（强制）

1) 主编排器禁止用“subagent 同步执行”的方式跑 worker  
典型错误：主编排器直接调用 `/java-stage1-coverage-worker` 或以 subagent 方式执行它，导致主会话被阻塞，用户无法交互。

2) worker 必须作为独立 teammate（独立任务）运行  
主编排器只能做：
- 领取页任务（DB 原子领取）
- 创建/复用 teammate
- 给 teammate 下发任务参数
- 轮询 DB 观察进度与收尾决策

3) 主编排器不得等待“teammate 完成”作为唯一进度来源  
主编排器应以 DB 为真相：定期查询 `stage1_pages/stage1_classes` 的进度，并随时响应用户“进度/卡点/告警”询问（可调用 `java-stage1-status-checker`）。

## 参考执行模板（以 Claude Code 的 Team 能力为准）

不同环境的具体按钮/命令名可能略有差异，但步骤语义必须一致：

1) 创建 team（若尚未创建）
- TeamCreate

2) 创建 teammate（worker）并加入 team
- 创建一个 teammate（角色：worker）
- 确保该 teammate 是独立运行（不会阻塞主会话）

3) 给 teammate 发送任务（每个 page 一条）
- SendMessage 给 teammate
- 消息内容必须包含：`run_id/worker_id/page_no/page_size/source_path/output_path`
- teammate 接到消息后执行 `/java-stage1-coverage-worker` 并只处理该页

4) 主编排器轮询 DB
- 用 `stage1_run_progress(run_id)` 观察覆盖率
- 用 `SELECT ... FROM stage1_pages WHERE status<>'done'` 找卡点/重试页

