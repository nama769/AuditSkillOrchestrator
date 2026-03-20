---
name: java-stage1-auth-marker
description: Java 阶段1 鉴权相关标记器（独立版）。输入一个类的“局部代码上下文”（通常是若干方法源码片段），仅基于该文本识别与鉴权/访问控制相关的 Filter/Interceptor/Aspect/注解/配置类与关键 API，并输出 auth_marker 记录数组，供 worker 写入 auth_markers.jsonl。本阶段只标记相关性，不深入分析鉴权正确性或绕过。
---

# Stage1 Auth Marker（单类）

你只分析“一个类”的局部代码上下文，输出与鉴权/权限控制相关的标记记录。

## 输入

- `class_name`
- `page_no`
- `code_context`（若干方法源码/片段拼接而成，可能不包含完整类声明/类注解）
- 可选：`source_file`

## 输出（固定为一个 JSON 对象）

- `records`：数组（每个元素是 auth_markers.jsonl 的一行结构）
- `errors`：字符串数组

输出强约束：
- 每条记录必须包含：`record_type="auth_marker"`、`marker_type`、`framework`、`class_name`、`evidence.reason`、`confidence`、`page_no`
- `marker_type` 必须是 schema 枚举之一：`filter`/`interceptor`/`aspect`/`annotation`/`config`/`middleware`/`session`/`token`/`rbac`/`acl`/`other`
- 禁止输出自定义大写类型（例如 `AUTH_TOKEN`）；不确定时用 `token` 或 `other`，并在 reason 说明

## 标记规则（仅基于 code_context）

你只做“相关性标记”，不做漏洞识别与正确性判断。命中任意模式即可输出记录；不确定时降低 `confidence`，并把不确定性写进 `evidence.reason`。

### 1) Filter 组件（marker_type=filter）

命中条件（任一即可）：
- `implements javax.servlet.Filter` / `jakarta.servlet.Filter`
- `extends OncePerRequestFilter`（Spring）
- 出现 `doFilter(...)` / `doFilterInternal(...)`
- 出现 `@WebFilter(...)`（`filterName/urlPatterns/initParams`）

常见“鉴权相关性”证据（出现即可标记）：
- 读取身份输入：`request.getHeader("Authorization")`、`getHeader(...)`、`getCookies()`、`getSession(false)`
- 读取/写入会话：`HttpSession#getAttribute/setAttribute`
- 访问路由信息：`getRequestURI/getServletPath/getPathInfo`

### 2) Interceptor 组件（marker_type=interceptor）

命中条件（任一即可）：
- `implements HandlerInterceptor` 且出现 `preHandle(...)`
- 出现典型注册模式（仍仅基于当前 code_context）：
  - `implements WebMvcConfigurer` + `addInterceptors(InterceptorRegistry)`
  - `registry.addInterceptor(...)`、`.addPathPatterns(...)`、`.excludePathPatterns(...)`

与注解/路由联动的证据（出现即可标记）：
- `handler instanceof HandlerMethod`
- `HandlerMethod#hasMethodAnnotation(...)`
- `getBeanType().isAnnotationPresent(...)`

### 3) Aspect / AOP（marker_type=aspect）

命中条件（任一即可）：
- `@Aspect` / `@Around(...)`
- `ProceedingJoinPoint`、`pjp.proceed()`
- `@EnableAspectJAutoProxy`、`@Order(...)`（作为“安全中间件/鉴权切面”线索）

### 4) 注解式鉴权（marker_type=annotation）

命中任一注解即可标记（类/方法级）：
- Spring Security：`@PreAuthorize`、`@PostAuthorize`、`@PreFilter`、`@PostFilter`、`@Secured`、`@RolesAllowed`
- JSR-250：`@PermitAll`、`@DenyAll`
- Shiro：`@RequiresAuthentication`、`@RequiresUser`、`@RequiresGuest`、`@RequiresRoles`、`@RequiresPermissions`
- 自定义鉴权注解线索：注解名包含 `Auth/Role/Permission/Acl/Rbac/Anonymous` 等语义，或被 AOP/Interceptor 代码显式读取

### 5) 配置类 / 框架启用（marker_type=config）

Spring Security 命中：
- `@EnableWebSecurity`
- `SecurityFilterChain`（`@Bean` 方法）
- `extends WebSecurityConfigurerAdapter`（旧式）
- `@EnableGlobalMethodSecurity(...)`（方法级安全启用）
- `HttpSecurity`（`authorizeHttpRequests/authorizeRequests`、`requestMatchers/antMatchers/mvcMatchers/regexMatchers`、`permitAll/authenticated/hasRole/hasAnyRole`）

Shiro 命中：
- `ShiroFilterFactoryBean`
- `setFilterChainDefinitionMap(...)`
- `AuthorizingRealm`、`AccessControlFilter`、`SecurityManager`

Session/Cookie 配置线索（仅基于源码内出现的 API/类型）：
- `SessionCookieConfig`、`ServletContextInitializer`
- `Cookie` 相关的身份字段处理

### 6) 运行时关键 API（按框架归类）

Spring Security 运行时：
- `SecurityContextHolder`、`Authentication`、`UsernamePasswordAuthenticationToken`
- `GrantedAuthority`/`SimpleGrantedAuthority`
- `UserDetailsService`/`UserDetails`
- `PasswordEncoder`

Shiro 运行时：
- `SecurityUtils`、`Subject`（`isAuthenticated/hasRole/isPermitted/login`）
- `AuthenticationInfo`、`AuthorizationInfo`

JWT：
- `io.jsonwebtoken.*`（`Jwts/JwtParser/Claims/parseClaimsJws`）
- `com.auth0.jwt.*`
- `JwtDecoder/JwtEncoder`（Spring Security）
- 典型 Bearer 解析流程（`Authorization` + `Bearer ` + `substring(7)`）

### 7) 类名/文件名模式（低/中置信度补充召回）

当类名命中下列模式时，即使未发现明确 API/注解，也可以输出一条低置信度标记（evidence 说明“基于命名模式”）：
- `*SecurityConfig*`、`*WebSecurityConfigurer*`、`*AuthenticationProvider*`、`*UserDetailsService*`、`*AccessDecision*`
- `*Realm*`、`*ShiroConfig*`、`*ShiroFilter*`
- `*Filter*`、`*AuthFilter*`、`*TokenFilter*`、`*Interceptor*`、`*AuthInterceptor*`、`*Jwt*`、`*TokenProvider*`

输出要求：
1) `marker_type` 与 `framework` 尽量准确；不确定则 `unknown/custom`
2) `evidence.reason` 必须存在，并尽量补充 `annotation`/`api`/`implements_or_extends`
3) 只标记相关性：不要在本阶段判断“是否鉴权生效”
