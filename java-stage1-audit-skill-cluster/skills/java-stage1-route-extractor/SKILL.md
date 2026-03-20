---
name: java-stage1-route-extractor
description: Java 阶段1 路由提取器（独立版）。输入一个类的“局部代码上下文”（通常是若干方法源码片段），仅基于该文本识别 Controller/Servlet/JAX-RS 等端点定义，输出 route 记录数组，供 worker 写入 routes.jsonl。不生成 Burp 模板，不做参数深挖，禁止跨文件搜索。
---

# Stage1 Route Extractor（单类）

你只分析“一个类”的局部代码上下文并输出能从该上下文中确定的路由映射记录。

## 输入

- `class_name`
- `page_no`
- `code_context`（若干方法源码/片段拼接而成，可能不包含完整类声明/类注解）
- 可选：`source_file`

## 输出（固定为一个 JSON 对象）

- `records`：数组（每个元素是 routes.jsonl 的一行结构）
- `errors`：字符串数组

输出强约束：
- 每条记录必须包含：`record_type="route"`、`framework`、`http_method`、`path`、`class_name`、`evidence.reason`、`page_no`
- 禁止输出自定义字段（例如 `line_number`）；行号字段只能用 `line_start/line_end`（无法确定可为 null）

## 识别要点（仅基于 code_context）

只做“识别与提取”，不做项目级搜索与跨文件推断。你必须把路由当作“可追溯的证据记录”：只能依据当前 `code_context` 中出现的注解/常量/分发逻辑生成记录。若缺少类级信息（例如类注解/父类/接口），不要臆测，按 `(unknown)` 输出并在 evidence 说明缺失原因。

### 1) Spring MVC / Spring Boot（framework=spring_mvc）

命中条件（任一即可）：
- 类上出现 `@Controller` / `@RestController` / `@RequestMapping`
- 方法上出现 `@RequestMapping` / `@GetMapping` / `@PostMapping` / `@PutMapping` / `@PatchMapping` / `@DeleteMapping`

提取字段与组合规则：
- 类级路径前缀：类上的 `@RequestMapping`（`value`/`path`，支持数组多值）
- 方法级路径：方法上的 `@RequestMapping`（`value`/`path`，支持数组多值）或 `@GetMapping(...)/@PostMapping(...)` 等
- HTTP 方法：
  - `@GetMapping` 等直接确定
  - `@RequestMapping(method=...)` 可为单个或数组
  - 未声明则 `http_method="*"`
- 条件路由元数据（写进 `evidence`，不要丢弃）：`params`、`headers`、`consumes`、`produces`

输出策略（需要完整枚举）：
- 多值组合：类级路径(可多) × 方法级路径(可多) × HTTP 方法(可多) 需要展开为多条记录
- 规范化：避免重复斜杠，空字符串按“无额外路径”处理
- 路径变量与通配符：保留原样（如 `/user/{id}`、`/api/**`、`{v:regex}`），并在 `evidence` 记录 `path_variables`/`wildcards`（如果能从文本中提取）

### 2) JAX-RS（framework=jax_rs）

命中条件（任一即可）：
- 使用 `javax.ws.rs.*` 或 `jakarta.ws.rs.*`
- 类/方法出现 `@Path`

提取字段与组合规则：
- 类级 `@Path` + 方法级 `@Path` 组合成最终 path（方法级可缺省）
- HTTP 方法注解：`@GET/@POST/@PUT/@DELETE/@PATCH/@HEAD/@OPTIONS`
- `@Consumes/@Produces` 作为元数据写入 `evidence`
- 路径参数：保留 `{id}`、`{path:.*}` 之类原样，并在 `evidence` 标注 `path_params`（能从文本提取就写）

### 3) Servlet（framework=servlet）

命中条件（任一即可）：
- 类上 `@WebServlet(...)`（字段可能是 `urlPatterns` 或 `value`，支持数组）
- `extends HttpServlet`

提取规则：
- URL pattern：
  - 能从 `@WebServlet` 提取则直接用该 pattern（`/api/*`、`*.do` 等）
  - 若只有 `extends HttpServlet` 且未出现 `@WebServlet`，则 `path="(unknown)"` 并在 `evidence` 写明“URL 来源通常在 web.xml，当前 code_context 无法确定”
- HTTP 方法集合：根据是否覆盖 `doGet/doPost/doPut/doDelete/doPatch/doHead/doOptions` 推断；都看不到则 `http_method="*"`
- 通配符子路径推断（仅基于当前类源码）：
  - 若看到 `request.getPathInfo()` / `request.getServletPath()` / `getRequestURI()` 分发逻辑（if/switch/equals/startsWith），尝试枚举常量比较的子路径并输出额外 route 记录
  - 推断不完整时仍保留原 pattern 记录，并在 `evidence` 写明推断依据与不完整原因

### 4) Struts2 Action（framework=struts2，尽量提取，否则标记 unknown）

命中条件（任一即可）：
- `extends ActionSupport` / `implements Action`
- 出现 `org.apache.struts2.*`、`com.opensymphony.xwork2.*`

提取策略（受限于局部上下文）：
- 通常 URL 来自 `struts.xml`，若当前 `code_context` 无法获得 namespace/action name，则：
  - 输出一条 `path="(unknown)"`、`http_method="*"` 的记录
  - 在 `evidence` 写明“Struts2 Action 类命中，但缺少 struts.xml 映射”
- 若出现明显的动态方法分发模式（如 `!method` 相关字符串/解析），在 `evidence` 标注 `dynamic_dispatch=true`

### 5) WebService / JAX-WS（framework=webservice）

命中条件（任一即可）：
- `@WebService` / `@WebMethod` / `javax.jws.*`

提取策略：
- WebService 的 URL 通常来自 Spring XML/Servlet 映射；局部上下文通常无法确认 URL：
  - 输出 `path="(unknown)"`、`http_method="*"`
  - 在 `evidence` 写明“WebService endpoint 命中，URL 需配置文件提供”

### 6) 额外攻击面入口（framework=other）

只要在 `code_context` 中出现即可输出记录（用于后续阶段扩展，不等同于 HTTP 路由）：
- WebSocket：`@ServerEndpoint`、`@MessageMapping`
- RPC/服务入口：`@DubboService/@Service`（Dubbo）、`@FeignClient`、gRPC service base class

输出约定：
- `http_method="*"`
- `path` 能从注解中取到就写，否则 `(unknown)`
- `evidence.reason` 明确写“非 HTTP 路由，作为入口标记”

输出要求：
1) `evidence.reason` 必须存在（写明命中注解/父类/接口）
2) path 无法确定时：`path="(unknown)"`，并在 evidence 说明缺少的配置来源（例如 web.xml/struts.xml）
