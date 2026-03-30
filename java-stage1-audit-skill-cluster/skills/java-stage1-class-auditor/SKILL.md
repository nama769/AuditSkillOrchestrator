---
name: java-stage1-class-auditor
description: Java Stage1 备用单类三维审计器。需要对单个 class 做集中复核或手工补审时，可用本技能一次返回严格 schema 的 sinks、routes、auth_markers 与 code_context_level。默认页级 worker 流程不再依赖本技能。禁止跨文件搜索或推测未提供内容。
---

# Stage1 单类三维审计（一次输出）

你只分析一个 class（以 `class_name` 指定），并在同一上下文中同时输出：
- `sinks`
- `routes`
- `auth_markers`

你不能搜索项目、不能读取其他文件、不能推断未提供的配置。

## 核心原则（强制）

你必须复用现有三个技能的完整审计流程与技术细节，不允许在本技能中做“简化版规则”替代：
- `/java-stage1-sink-extractor`
- `/java-stage1-route-extractor`
- `/java-stage1-auth-marker`

本技能的职责是：在同一个上下文中依次执行三次分析，并把三者输出合并为一次 JSON 返回，适合单类复核、抽样检查或人工补审。

## 输入

上游会提供：
- `class_name`
- `page_no`

## 输出（只输出一个 JSON 对象）

```json
{
  "code_context_level": "members_only",
  "sinks": [],
  "routes": [],
  "auth_markers": [],
  "errors": []
}
```

输出强约束（必须满足，否则视为失败）：
- `code_context_level` 必须存在，且只能是：`members_only` 或 `method_source`
- `sinks/routes/auth_markers/errors` 必须全部存在，且为数组
- 禁止输出任何额外顶层字段
- 每条记录必须严格符合 schema（字段名/枚举值必须正确）

## 执行流程（强制按步骤）

0) Members 粗筛（强制，先做）
- 先调用 `get_methods_of_class(class_name)` 获取该类的“方法签名列表”
- 再调用 `get_fields_of_class(class_name)` 获取该类的“字段列表”
- 仅基于方法签名与字段信息，判断这个类是否可能包含 sink/route/auth 相关内容：
  - 若明显不相关：不要再拉取任何源码；`code_context_level="members_only"`；三类结果全部输出空数组即可
  - 若可能相关：进入下一步，选择“少量可疑方法”拉取源码；最终 `code_context_level="method_source"`

粗筛提示（只用于“是否值得拉源码”的判断，不直接产出 findings）：
- route 倾向信号：方法名包含 `doGet/doPost/service/handle/request/dispatch`；参数类型出现 `javax.servlet.*`/`jakarta.servlet.*`；类/方法名包含 `Controller/Resource/Servlet/Action/Endpoint`
- auth 倾向信号：方法名包含 `doFilter/preHandle/intercept/auth/login/logout/permit/deny/role/permission`；参数类型出现 `FilterChain`/`HttpServletRequest`；字段类型/名包含 `token/session/auth/security/shiro/jwt`
- sink 倾向信号：方法名包含 `exec/execute/query/update/prepare/eval/invoke/load/readObject/deserialize`；参数/字段类型出现 `java.sql.*`/`javax.sql.*`/`javax.naming.*`/`Runtime`/`ProcessBuilder`

1) 按需拉取方法源码（只用 get_method_by_name）
- 你禁止使用 `get_class_source` 拉取整个类
- 对于你判断“可能相关”的方法，调用 `get_method_by_name(class_name, method_name)` 拉取方法源码
- 优先使用“完整签名格式”的 `method_name` 参数（用于重载/构造函数）：
  - `methodName(full.qualified.ParamType1, full.qualified.ParamType2):returnType`
  - 构造函数：`<init>(...):void`
- 如果方法无重载且你拿不到完整签名，可以退化为仅传普通方法名（例如 `doGet`）
- 拉取数量控制：总计不超过 12 个方法源码；如果候选过多，优先选择更“入口/高危/框架相关”的方法名与签名

2) 调用 `/java-stage1-sink-extractor`
- 输入：`class_name/page_no` + 你已拉取的方法源码文本（作为 `code_context`）
- 要求：严格按 sink-extractor 的规则识别与输出（包括其规则库与证据要求）

3) 调用 `/java-stage1-route-extractor`
- 输入：`class_name/page_no` + 你已拉取的方法源码文本（作为 `code_context`）
- 要求：严格按 route-extractor 的识别要点（框架覆盖、字段与组合规则、pattern 处理、evidence）输出 routes 记录

4) 调用 `/java-stage1-auth-marker`
- 输入：`class_name/page_no` + 你已拉取的方法源码文本（作为 `code_context`）
- 要求：严格按 auth-marker 的相关性模式要点输出 auth_markers（不做漏洞识别）

5) 合并与纠偏（仅做安全纠偏）
- 将三次调用返回的 `records` 分别填入本技能输出的 `sinks/routes/auth_markers`
- 若子技能返回记录的 `class_name/page_no` 缺失或与输入不一致：以输入的 `class_name/page_no` 为准修正，并在 `errors` 记录一次说明
- 不要更改子技能的证据内容（尤其是 evidence.reason/snippet/api）

## sinks 输出规则（严格 schema）

每条 sink 记录必须包含：
- `record_type`: 固定 `"sink"`
- `sink_type`: 小写枚举（`sql/cmd_exec/ssrf/file_read/file_write/deserialize/xxe/template/spel/ognl/jndi/ldap/runtime_reflect/response_write/redirect/xpath/other`）
- `class_name`: 使用输入的 class_name
- `method_name`: 必须是具体方法名（不得为 null/空）
- `evidence.reason`: 必须存在且非空；尽量补充 `api/snippet`
- `confidence`: `high|medium|low`
- `page_no`: 使用输入的 page_no

## routes 输出规则（严格 schema）

每条 route 记录必须包含：
- `record_type`: 固定 `"route"`
- `framework`: `spring_mvc|jax_rs|servlet|struts2|webservice|other`
- `http_method`: `GET/POST/PUT/DELETE/PATCH/OPTIONS/HEAD/*`
- `path`: 字符串（未知写 `(unknown)`）
- `class_name`: 使用输入的 class_name
- `evidence.reason`: 必须存在且非空
- `page_no`: 使用输入的 page_no

routes 的全部识别要点以 `/java-stage1-route-extractor` 为准（本技能不重复定义，避免分叉）。

## auth_markers 输出规则（严格 schema）

每条 auth_marker 记录必须包含：
- `record_type`: 固定 `"auth_marker"`
- `marker_type`: `filter|interceptor|aspect|annotation|config|middleware|session|token|rbac|acl|other`
- `framework`: `spring_security|shiro|jwt|custom|unknown`
- `class_name`: 使用输入的 class_name
- `evidence.reason`: 必须存在且非空
- `confidence`: `high|medium|low`
- `page_no`: 使用输入的 page_no

auth_markers 的全部模式要点以 `/java-stage1-auth-marker` 为准（本技能不重复定义，避免分叉）。

## errors

只要你遇到以下情况就往 errors 追加字符串说明（不要中断输出）：
- schema 字段无法填充（例如 method_name 无法确定）
- 证据不足导致 confidence 降为 low
- 发现疑似入口但无法确认 path，需要配置文件支持
