---
title: Stage1 快速开始
---

# 阶段1 快速开始（100% 覆盖）

本版本使用 Postgres（DB: javaAudit）作为阶段1的唯一状态后端：
- pages/classes/warnings/sinks/routes/auth_markers 全部写入数据库
- 覆盖率统计以数据库聚合为准

## 启动

在 Claude Code 中：
```
/java-stage1-coverage-orchestrator {source_path} --output {output_path}
```

## 第一次运行：建表

用 Postgres MCP 的 `execute_sql` 执行：
- `java-stage1-audit-skill-cluster/db/ddl.sql`

## 运行中检查（全部通过 SQL）

1) 覆盖率：
```sql
SELECT COALESCE(SUM(done_class_count),0) AS done,
       COALESCE(SUM(expected_class_count),0) AS expected
FROM stage1_pages
WHERE run_id='{run_id}';
```

2) 未完成页：
```sql
SELECT page_no, status, expected_class_count, done_class_count, assigned_to
FROM stage1_pages
WHERE run_id='{run_id}' AND status <> 'done'
ORDER BY page_no;
```

覆盖率必须为 100%：
- `done == expected`
- 且不存在非 done 的页
