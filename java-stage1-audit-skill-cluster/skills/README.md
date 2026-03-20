***

## title: Java Stage1 Audit Skill Cluster

# Java 阶段1审计 Skill 集群（100% 覆盖）

本目录是一套**独立**的阶段1审计 skill 集群

阶段1核心目标：

- 对目标项目做“按类枚举”的 100% 覆盖扫描
- 输出全量：sink 点（方法级）/ 路由映射（接口→类→方法）/ 鉴权相关标记（Filter/Interceptor/Aspect/注解/配置等，仅标记相关性）
- 所有记录与状态写入 Postgres（DB: javaAudit），覆盖率通过 SQL 可验证统计

## 目录结构

```
java-stage1-audit-skill-cluster/
└── skills/
    ├── java-stage1-coverage-orchestrator/   # 主编排器（Agent Teams）
    ├── java-stage1-coverage-worker/         # 按页 worker（由主编排器调度）
    ├── java-stage1-class-auditor/           # 单类三维审计（由 worker 创建 subagent 调用）
    ├── java-stage1-sink-extractor/          # 单类 sink 提取器（由 worker 调用）
    ├── java-stage1-route-extractor/         # 单类路由提取器（由 worker 调用）
    ├── java-stage1-auth-marker/             # 单类鉴权相关标记器（由 worker 调用）
    └── java-stage1-status-checker/          # 主 agent 状态探针（查询进度/卡点/告警）
```

## 运行前置

- 已开启 Claude Code agent teams：`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- 已配置 `jadx-ai-mcp`，至少包含：
  - `get_all_classes(offset, count)`
  - `get_methods_of_class(class_name)`
  - `get_fields_of_class(class_name)`
  - `get_method_by_name(class_name, method_name)`
- 已配置 Postgres MCP 并连接本地 `javaAudit` 数据库（至少支持 `execute_sql`）

## 使用入口

从主编排器开始：

- `skills/java-stage1-coverage-orchestrator/SKILL.md`

查询审计进度/恢复现场：
- `skills/java-stage1-status-checker/SKILL.md`
