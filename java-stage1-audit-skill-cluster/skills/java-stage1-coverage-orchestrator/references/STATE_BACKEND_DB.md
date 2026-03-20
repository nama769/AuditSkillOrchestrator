---
title: Stage1 状态后端（数据库方案）
---

# 阶段1 状态后端：数据库方案（替代 class_list.jsonl）

## 结论

可以，而且更适合“高并发 + 长流程 + 可恢复”的审计编排：
- JSONL 文件更像日志：追加容易，但“领取任务/原子更新/去重/一致性校验”会变复杂
- 数据库更像状态机：天然支持事务、并发控制、幂等写入、断点续跑与覆盖率统计

本文件定义“数据库后端契约”，用于让 agent 通过 DB MCP 工具写入/更新/校验阶段1进度。

## DB MCP 工具能力要求（抽象契约）

不限定 MySQL/PostgreSQL/SQLite/Redis，但需要满足以下最小能力：
- `exec(query, params)`：执行 DDL/DML
- `query(query, params)`：查询并返回 rows
- 事务能力（至少能保证“领取一页任务”的原子性）

Redis 也可用，但需要提供等价的原子操作（例如 Lua / MULTI/EXEC / SETNX + TTL）。

## 最小表结构（关系型推荐：PostgreSQL/MySQL/SQLite）

### runs

- `run_id` TEXT PRIMARY KEY
- `created_at` TEXT
- `source_path` TEXT
- `output_path` TEXT
- `page_size` INTEGER
- `total_classes` INTEGER NULL
- `total_pages` INTEGER NULL
- `status` TEXT  -- running/done/failed

### pages

主编排器的页级调度与覆盖率统计。

- `run_id` TEXT
- `page_no` INTEGER
- `status` TEXT  -- pending/in_progress/done/needs_retry
- `assigned_to` TEXT NULL
- `assigned_at` TEXT NULL
- `expected_class_count` INTEGER NULL
- `done_class_count` INTEGER NULL
- `new_sink_count` INTEGER DEFAULT 0
- `new_route_count` INTEGER DEFAULT 0
- `new_auth_marker_count` INTEGER DEFAULT 0
- `error_count` INTEGER DEFAULT 0
- PRIMARY KEY (`run_id`, `page_no`)

### classes

worker 的逐类完成标记（替代 class_list.jsonl + class_update）。

- `run_id` TEXT
- `page_no` INTEGER
- `class_name` TEXT
- `origin` TEXT NULL
- `status` TEXT  -- pending/done/error
- `done_at` TEXT NULL
- `sink_count` INTEGER DEFAULT 0
- `route_count` INTEGER DEFAULT 0
- `auth_marker_count` INTEGER DEFAULT 0
- `errors` TEXT NULL  -- JSON 字符串或拼接文本
- PRIMARY KEY (`run_id`, `class_name`)

### findings（可选但推荐）

把 sinks/routes/auth_markers 也存进 DB（后续去重/聚合更容易），同时仍可落盘 JSONL 作为可读报告。

- `run_id` TEXT
- `page_no` INTEGER
- `class_name` TEXT
- `kind` TEXT  -- sink/route/auth_marker
- `payload` TEXT  -- 该条记录的 JSON 字符串（严格 schema）
- `created_at` TEXT

## 关键流程（原子领取）

### 初始化

1) 写入 runs
2) 写入 pages：对每个 page_no 插入一行 status=pending

### worker 领取一页（主编排器执行）

关系型数据库推荐用事务 + 条件更新实现“只领取一次”：

1) `BEGIN`
2) `SELECT page_no FROM pages WHERE run_id=? AND status IN ('pending','needs_retry') ORDER BY page_no LIMIT 1 FOR UPDATE`
3) `UPDATE pages SET status='in_progress', assigned_to=?, assigned_at=? WHERE run_id=? AND page_no=?`
4) `COMMIT`

### worker 完成上报（worker 执行）

1) 对本页 class 清单批量 upsert 到 classes（status=pending）
2) 每完成一个 class：更新 classes.status/done_at/count/errors
3) 完成页统计：更新 pages.expected_class_count/pages.done_class_count/计数

### 覆盖率校验（主编排器执行）

`SELECT SUM(done_class_count), SUM(expected_class_count) FROM pages WHERE run_id=?`

完成判定：
- 所有页 `done_class_count == expected_class_count`
- 覆盖率 100%

## 与落盘 JSONL 的关系（推荐策略）

推荐“双写”：
- DB 作为状态真相（调度/完成/统计以 DB 为准）
- JSONL 作为可读审计产物（便于人工查看与后续工具消费）

如果只想要 DB：
- 仍建议至少落盘 warnings 与 summary，便于排障

