---
title: Stage1 状态查询 SQL
---

# Stage1 状态查询 SQL（只读）

所有 SQL 只读执行，用 `{run_id}` 替换对应值。

## 1) 最近 runs（未提供 run_id 时使用）

```sql
SELECT run_id, status, created_at, source_path, output_path, page_size, total_pages, total_classes
FROM stage1_runs
ORDER BY created_at DESC
LIMIT 5;
```

如果已安装 `db/views.sql`，也可以：
```sql
SELECT run_id, status, created_at, source_path, output_path, page_size, total_pages, total_classes
FROM stage1_runs_latest
LIMIT 5;
```

## 2) Run 概览（单条）

```sql
SELECT run_id, status, created_at, source_path, output_path, page_size, total_pages, total_classes
FROM stage1_runs
WHERE run_id = '{run_id}';
```

## 3) 覆盖率（done/expected）

```sql
SELECT
  COALESCE(SUM(done_class_count),0) AS done,
  COALESCE(SUM(expected_class_count),0) AS expected
FROM stage1_pages
WHERE run_id = '{run_id}';
```

如果已安装 `db/functions.sql`，推荐：
```sql
SELECT * FROM stage1_run_progress('{run_id}');
```

## 4) 页状态计数

```sql
SELECT status, COUNT(*) AS cnt
FROM stage1_pages
WHERE run_id = '{run_id}'
GROUP BY status
ORDER BY cnt DESC, status;
```

## 5) 长时间 in_progress 页（默认 20 分钟阈值）

```sql
SELECT page_no, status, assigned_to, assigned_at, expected_class_count, done_class_count
FROM stage1_pages
WHERE run_id = '{run_id}'
  AND status = 'in_progress'
  AND assigned_at IS NOT NULL
  AND assigned_at < now() - interval '20 minutes'
ORDER BY assigned_at ASC
LIMIT 20;
```

## 6) needs_retry 页

```sql
SELECT page_no, status, assigned_to, assigned_at, expected_class_count, done_class_count, last_error
FROM stage1_pages
WHERE run_id = '{run_id}'
  AND status = 'needs_retry'
ORDER BY page_no
LIMIT 20;
```

## 7) expected_class_count 为空的页数量（用于判断是否尚未被领取/写入清单）

```sql
SELECT COUNT(*) AS null_expected_pages
FROM stage1_pages
WHERE run_id = '{run_id}'
  AND expected_class_count IS NULL;
```

## 8) Worker 汇总（近 60 分钟）

```sql
SELECT
  COALESCE(assigned_to, '(unassigned)') AS worker_id,
  COUNT(*) FILTER (WHERE status = 'in_progress') AS in_progress_pages,
  COUNT(*) FILTER (WHERE status = 'done') AS done_pages
FROM stage1_pages
WHERE run_id = '{run_id}'
  AND (assigned_at IS NULL OR assigned_at > now() - interval '60 minutes')
GROUP BY COALESCE(assigned_to, '(unassigned)')
ORDER BY in_progress_pages DESC, done_pages DESC, worker_id;
```

## 9) 最近 warnings（50 条）

```sql
SELECT time, level, worker_id, page_no, class_name, message
FROM stage1_warnings
WHERE run_id = '{run_id}'
ORDER BY time DESC
LIMIT 50;
```

## 10) warnings Top（按 message 聚合）

```sql
SELECT message, COUNT(*) AS cnt
FROM stage1_warnings
WHERE run_id = '{run_id}'
GROUP BY message
ORDER BY cnt DESC, message
LIMIT 10;
```

## 11) 类级 code_context_level 分布（用于衡量“只枚举未拉源码”的占比）

```sql
SELECT code_context_level, COUNT(*) AS cnt
FROM stage1_classes
WHERE run_id = '{run_id}'
GROUP BY code_context_level
ORDER BY cnt DESC, code_context_level;
```
