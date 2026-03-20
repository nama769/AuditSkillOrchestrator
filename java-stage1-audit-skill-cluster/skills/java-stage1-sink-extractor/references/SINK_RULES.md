# Sink 漏洞模式库

每类漏洞包含关键函数和**局部确认条件**（仅在 Sink 方法内部可判断的条件）。

***

## 目录

1. [反序列化](#1-反序列化)
2. [JNDI 注入](#2-jndi-注入)
3. [表达式注入](#3-表达式注入)
4. [命令注入](#4-命令注入)
5. [SQL 注入](#5-sql-注入)
6. [任意类实例化](#6-任意类实例化)
7. [不安全反射](#7-不安全反射)
8. [JDBC 连接攻击](#8-jdbc-连接攻击)
9. [文件上传](#9-文件上传)
10. [ZipSlip](#10-zipslip)
11. [任意文件读取](#11-任意文件读取)
12. [硬编码敏感信息](#12-硬编码敏感信息)

***

## 1. 反序列化

**vuln\_type**: `deserialization`

### 无版本限制（直接搜索）

| 关键函数                               | 说明             |
| ---------------------------------- | -------------- |
| `ObjectInputStream.readObject()`   | JDK 原生反序列化     |
| `ObjectInputStream.readUnshared()` | JDK 原生反序列化     |
| `Hessian2Input.readObject()`       | Hessian 反序列化   |
| `HessianInput.readObject()`        | Hessian 反序列化   |
| `Yaml.load()`                      | SnakeYAML 反序列化 |
| `Yaml.loadAll()`                   | SnakeYAML 反序列化 |

### 需版本确认（先查依赖版本再搜索）

版本确认方式（按优先级）：

1. 从 `pom.xml` / `build.gradle` 中的依赖声明读取版本号
2. 从项目 `lib/` 目录下的 jar 文件名提取版本号（如 `fastjson-1.2.24.jar`）
3. 使用 `find_file` 搜索对应 jar 文件名模式

| 关键函数                                                 | 库        | 受影响版本                                    |
| ---------------------------------------------------- | -------- | ---------------------------------------- |
| `XMLDecoder.readObject()`                            | JDK      | 所有版本                                     |
| `JSON.parseObject()` / `JSON.parse()`                | Fastjson | ≥1.2.83 为安全版本                            |
| `ObjectMapper.readValue()` / `enableDefaultTyping()` | Jackson  | 开启 `DefaultTyping` 或使用 `@JsonTypeInfo` 时 |
| `XStream.fromXML()`                                  | XStream  | <1.4.17 默认无安全配置；≥1.4.17 默认启用白名单          |

### 局部确认条件

检查 Sink 方法内部：

1. 是否使用了 `ObjectInputFilter`(JDK9+) 或自定义 `resolveClass` 黑白名单 → 有则降低 confidence
2. 是否使用了 `SerialKiller`、`NotSoSerial` 等防护库 → 有则降低 confidence
3. 对于 SnakeYAML：是否使用了 `SafeConstructor`（`new Yaml(new SafeConstructor())` 是安全的）→ 有则排除
4. 对于需版本确认的库：版本不在受影响范围内 → 直接排除
5. 对于 Jackson：是否开启了 `enableDefaultTyping()` 或使用了 `@JsonTypeInfo(use=Id.CLASS)` → 未开启则排除

***

## 2. JNDI 注入

**vuln\_type**: `jndi_injection`

**关键函数**:

| 关键函数                                    | 说明                        |
| --------------------------------------- | ------------------------- |
| `InitialContext.lookup(name)`           | 直接 JNDI 查找                |
| `Context.lookup(name)`                  | 直接 JNDI 查找                |
| `DirContext.lookup(name)`               | 目录上下文查找                   |
| `JndiTemplate.lookup(name)`             | Spring JNDI 模板            |
| `JndiLocatorDelegate.lookup(name)`      | Spring JNDI 定位            |
| `JdbcRowSetImpl.setDataSourceName(url)` | 间接触发 JNDI lookup          |
| `LdapTemplate.lookup(dn)`               | Spring LDAP 查找            |
| `InitialDirContext(env)`                | 通过环境变量中的 PROVIDER\_URL 触发 |

### 局部确认条件

检查 Sink 方法内部：

1. lookup 参数是否为硬编码字符串常量（如 `"java:comp/env/jdbc/mydb"`）→ 硬编码则排除
2. 是否有协议前缀白名单校验（如仅允许 `java:comp/env/` 前缀）→ 有则降低 confidence
3. 是否有格式校验（如禁止 `ldap://`、`rmi://`、`dns://` 前缀）→ 有则降低 confidence
4. lookup 参数是否来自方法参数（而非方法内部构造）→ 来自参数则 confidence 更高

***

## 3. 表达式注入

**vuln\_type**: `expression_injection`

**关键函数**:

| 关键函数                                            | 引擎        | 说明                         |
| ----------------------------------------------- | --------- | -------------------------- |
| `SpelExpressionParser.parseExpression(expr)`    | SpEL      | Spring 表达式解析               |
| `Expression.getValue()`                         | SpEL      | 表达式求值                      |
| `ExpressionParser.parseExpression()`            | SpEL      | 通用接口                       |
| `Ognl.getValue(expr, ctx, root)`                | OGNL      | OGNL 表达式求值                 |
| `Ognl.setValue(expr, ctx, root, value)`         | OGNL      | OGNL 表达式赋值                 |
| `OgnlUtil.getValue(expr)`                       | OGNL      | Struts2 OGNL 工具            |
| `OgnlUtil.setValue(expr)`                       | OGNL      | Struts2 OGNL 工具            |
| `ActionContext.getValueStack().findValue(expr)` | OGNL      | Struts2 值栈                 |
| `ScriptEngine.eval(script)`                     | JSR-223   | JavaScript/Groovy/Python 等 |
| `ScriptEngineManager.getEngineByName().eval()`  | JSR-223   | 同上                         |
| `GroovyShell.evaluate(script)`                  | Groovy    | Groovy 脚本执行                |
| `GroovyShell.parse(script)`                     | Groovy    | Groovy 脚本解析                |
| `GroovyClassLoader.parseClass(script)`          | Groovy    | Groovy 类加载                 |
| `Mvel.eval(expr)`                               | MVEL      | MVEL 表达式                   |
| `MVEL.compileExpression(expr)`                  | MVEL      | MVEL 编译                    |
| `ELProcessor.eval(expr)`                        | EL        | Java EL 表达式                |
| `ValueExpression.getValue()`                    | EL        | JSF/EL 求值                  |
| `ExpressionFactory.createValueExpression(expr)` | EL        | EL 表达式创建                   |
| `Interpreter.eval(script)`                      | BeanShell | BeanShell 脚本               |
| `VelocityEngine.evaluate()`                     | Velocity  | 模板注入                       |

### 局部确认条件

检查 Sink 方法内部：

1. 对于 SpEL：使用的 EvaluationContext 类型 — `SimpleEvaluationContext` 是安全的（限制类型访问），`StandardEvaluationContext` 是危险的 → 使用 Simple 则排除
2. 表达式字符串是否为硬编码常量 → 硬编码则排除
3. 表达式参数是否来自方法参数 → 来自参数则 confidence 更高
4. 是否有对表达式字符串的沙箱/过滤逻辑 → 有则降低 confidence

***

## 4. 命令注入

**vuln\_type**: `command_injection`

**关键函数**:

| 关键函数                              | 说明     |
| --------------------------------- | ------ |
| `Runtime.getRuntime().exec(cmd)`  | 执行系统命令 |
| `Runtime.exec(cmd)`               | 同上     |
| `ProcessBuilder(command).start()` | 执行系统命令 |
| `ProcessBuilder.command(cmd)`     | 设置命令   |

### 局部确认条件

检查 Sink 方法内部：

1. 命令字符串是否为硬编码常量 → 硬编码则排除
2. 使用的是 `exec(String)` 还是 `exec(String[])` → `exec(String)` 更容易注入
3. 是否有对命令参数的 shell 元字符过滤（\`; | & $ \`\`）→ 有则降低 confidence
4. 是否有命令白名单校验 → 有则降低 confidence
5. 命令参数是否来自方法参数 → 来自参数则 confidence 更高

***

## 5. SQL 注入

**vuln\_type**: `sql_injection`

**关键函数**:

### JDBC 原生

| 关键函数                               | 说明           |
| ---------------------------------- | ------------ |
| `Statement.execute(sql)`           | 直接执行 SQL     |
| `Statement.executeQuery(sql)`      | 直接查询         |
| `Statement.executeUpdate(sql)`     | 直接更新         |
| `Connection.prepareStatement(sql)` | 若 sql 为拼接字符串 |
| `Connection.prepareCall(sql)`      | 存储过程调用       |

### JdbcTemplate (Spring)

| 关键函数                                         | 说明       |
| -------------------------------------------- | -------- |
| `JdbcTemplate.query(sql, ...)`               | 若 sql 拼接 |
| `JdbcTemplate.queryForObject(sql, ...)`      | 同上       |
| `JdbcTemplate.queryForList(sql, ...)`        | 同上       |
| `JdbcTemplate.update(sql, ...)`              | 同上       |
| `JdbcTemplate.execute(sql)`                  | 同上       |
| `NamedParameterJdbcTemplate.query(sql, ...)` | 若 sql 拼接 |

### Hibernate / JPA

| 关键函数                                   | 说明                  |
| -------------------------------------- | ------------------- |
| `EntityManager.createQuery(hql)`       | HQL 注入              |
| `EntityManager.createNativeQuery(sql)` | 原生 SQL              |
| `Session.createQuery(hql)`             | Hibernate HQL       |
| `Session.createSQLQuery(sql)`          | Hibernate 原生 SQL    |
| `Session.createNativeQuery(sql)`       | Hibernate 5+ 原生 SQL |
| `CriteriaBuilder` 配合字符串拼接              | JPA Criteria API 误用 |

### MyBatis

| 关键函数                              | 说明                  |
| --------------------------------- | ------------------- |
| MyBatis XML 中的 `${param}`         | 直接拼接，不转义 — **Sink** |
| MyBatis `@Select` 注解中的 `${param}` | 同上                  |
| `SqlRunner.selectOne(sql)`        | 原生 SQL              |

**注意**：MyBatis `#{param}` 是参数化写法，**不是 Sink**。

### 常见 SQL 注入场景

| 场景              | 示例                     |
| --------------- | ---------------------- |
| `order by` 动态排序 | `ORDER BY ${column}`   |
| `like` 模糊查询     | `LIKE '%${keyword}%'`  |
| `in` 条件         | `WHERE id IN (${ids})` |
| 表名/列名动态拼接       | `FROM ${tableName}`    |

### 局部确认条件

检查 Sink 方法内部：

1. SQL 字符串是否通过 `+` 拼接了变量（而非全部硬编码或使用 `?` 占位符）→ 使用 `PreparedStatement` + `?` 则排除
2. 对于 MyBatis：是否使用 `${}` 而非 `#{}` → 使用 `#{}` 则排除
3. 拼接的变量是否来自方法参数 → 来自参数则 confidence 更高，来自方法内部常量则排除
4. 是否有对拼接值的 SQL 转义或白名单校验 → 有则降低 confidence

***

## 6. 任意类实例化

**vuln\_type**: `arbitrary_class_instantiation`

**关键函数**:

| 关键函数                                           | 说明     |
| ---------------------------------------------- | ------ |
| `Class.forName(className)`                     | 按名称加载类 |
| `Class.forName(className).newInstance()`       | 加载并实例化 |
| `ClassLoader.loadClass(className)`             | 类加载器加载 |
| `Constructor.newInstance(args)`                | 反射实例化  |
| `Class.getDeclaredConstructor().newInstance()` | 反射实例化  |

### 利用条件（必须同时满足）

1. 类名可控 — 攻击者可指定要实例化的类
2. 构造函数为单 String 参数 — 目标类有 `Constructor(String)`
3. 构造参数可控 — 攻击者可控制传入的字符串值

### 局部确认条件

检查 Sink 方法内部：

1. `Class.forName()` / `loadClass()` 的参数是否为硬编码字符串 → 硬编码则排除
2. `getConstructor(String.class)` 是否硬编码为单 String 参数构造 → 结合利用条件 2 判定
3. `newInstance()` 的参数是否来自方法参数 → 来自参数则 confidence 更高
4. 是否有类名白名单校验 → 有则降低 confidence
5. 实例化后是否有类型强转限制（如 `(SomeInterface) instance`）→ 有限制则降低 confidence

***

## 7. 不安全反射

**vuln\_type**: `unsafe_reflection`

**关键函数**:

| 关键函数                                        | 说明        |
| ------------------------------------------- | --------- |
| `Method.invoke(obj, args)`                  | 反射调用方法    |
| `Field.set(obj, value)`                     | 反射设置字段    |
| `Field.get(obj)`                            | 反射获取字段    |
| `Constructor.newInstance(args)`             | 反射实例化     |
| `Class.getMethod(name, paramTypes)`         | 按名称获取方法   |
| `Class.getDeclaredMethod(name, paramTypes)` | 按名称获取声明方法 |
| `Class.getDeclaredField(name)`              | 按名称获取字段   |

### 局部确认条件

检查 Sink 方法内部：

1. 反射目标（方法名/字段名/类名字符串）是否为硬编码 → 硬编码则排除
2. 是否有对可反射的类/方法/字段的白名单限制 → 有则降低 confidence
3. 反射目标字符串是否来自方法参数 → 来自参数则 confidence 更高

***

## 8. JDBC 连接攻击

**vuln\_type**: `jdbc_attack`

**关键函数**:

### 连接建立

| 关键函数                                           | 说明                   |
| ---------------------------------------------- | -------------------- |
| `DriverManager.getConnection(url)`             | 直接建立 JDBC 连接         |
| `DriverManager.getConnection(url, user, pass)` | 同上                   |
| `DriverManager.getConnection(url, properties)` | 通过 Properties 传入连接参数 |

### 连接池配置

| 关键函数                                         | 说明                 |
| -------------------------------------------- | ------------------ |
| `HikariConfig.setJdbcUrl(url)`               | HikariCP 连接池       |
| `HikariDataSource.setJdbcUrl(url)`           | HikariCP 数据源       |
| `DruidDataSource.setUrl(url)`                | Alibaba Druid 连接池  |
| `DruidDataSource.setDriverClassName(driver)` | Druid 驱动设置         |
| `BasicDataSource.setUrl(url)`                | Apache DBCP 连接池    |
| `BasicDataSource.setDriverClassName(driver)` | DBCP 驱动设置          |
| `ComboPooledDataSource.setJdbcUrl(url)`      | C3P0 连接池           |
| `DataSource.getConnection()`                 | 通用数据源（检查 URL 配置来源） |

### 数据源动态创建

| 关键函数                                 | 说明                     |
| ------------------------------------ | ---------------------- |
| `DataSourceBuilder.url(url).build()` | Spring Boot 动态数据源构建    |
| `new JdbcTemplate(dataSource)`       | 若 dataSource 的 URL 可控  |
| `AbstractRoutingDataSource`          | 动态数据源路由（检查数据源 map 的来源） |

### 局部确认条件

检查 Sink 方法内部：

1. JDBC URL 是否为硬编码配置 → 硬编码则排除
2. JDBC URL 或连接池配置是否来自方法参数 → 来自参数则 confidence 更高
3. 是否有对 JDBC URL 的协议/主机白名单校验 → 有则降低 confidence
4. 是否有对 JDBC URL 参数（如 `autoDeserialize`、`INIT`、`socketFactory`）的过滤 → 有则降低 confidence
5. 常见场景：数据源管理功能、数据库连接测试接口、多租户动态数据源切换

***

## 9. 文件上传

**vuln\_type**: `file_upload`

**关键函数**:

| 关键函数                                        | 说明               |
| ------------------------------------------- | ---------------- |
| `MultipartFile.transferTo(dest)`            | Spring 文件保存      |
| `MultipartFile.getInputStream()`            | 获取上传流            |
| `MultipartFile.getOriginalFilename()`       | 获取原始文件名          |
| `Part.write(fileName)`                      | Servlet 3.0 文件保存 |
| `Part.getInputStream()`                     | Servlet 3.0 获取流  |
| `FileUtils.copyInputStreamToFile(in, dest)` | Commons IO 文件保存  |
| `Files.copy(in, path)`                      | NIO 文件复制         |
| `FileOutputStream(path)` 配合上传流              | 直接写文件            |

### 局部确认条件

检查 Sink 方法内部：

1. 是否校验了文件后缀（禁止 `.jsp`、`.jspx`、`.war` 等）→ 无校验则 confidence 高
2. 是否校验了文件名中的路径遍历字符（`../`）→ 无校验则 confidence 高
3. 是否校验了文件内容（Magic Bytes / MIME 类型）→ 无校验则 confidence 高
4. 保存路径是否在 Web 可访问目录下（如 `webapp/upload/`）→ 在则 confidence 更高

***

## 10. ZipSlip

**vuln\_type**: `zip_slip`

**关键函数**:

| 关键函数                            | 说明        |
| ------------------------------- | --------- |
| `ZipEntry.getName()`            | 获取压缩包内文件名 |
| `ZipInputStream.getNextEntry()` | 遍历 ZIP 条目 |
| `ZipFile.entries()`             | 枚举 ZIP 条目 |
| `TarArchiveEntry.getName()`     | TAR 包条目名  |
| `JarEntry.getName()`            | JAR 条目名   |

### 局部确认条件

检查 Sink 方法内部：

1. `entry.getName()` 获取文件名后是否直接拼接到目标目录 → 直接拼接则 confidence 高
2. 是否对文件名进行了 `../` 路径遍历检查 → 有检查则排除
3. 是否使用了 canonical path 校验 → 有校验则排除
4. 安全写法示例：`if (destFile.getCanonicalPath().startsWith(destDir.getCanonicalPath()))` — 有此模式则排除

***

## 11. 任意文件读取

**vuln\_type**: `arbitrary_file_read`

**关键函数**:

| 关键函数                                  | 说明              |
| ------------------------------------- | --------------- |
| `new FileInputStream(path)`           | 读取文件流           |
| `new FileReader(path)`                | 读取文件            |
| `Files.readAllBytes(path)`            | NIO 读取全部内容      |
| `Files.newInputStream(path)`          | NIO 输入流         |
| `Files.lines(path)`                   | NIO 按行读取        |
| `FileUtils.readFileToString(file)`    | Commons IO 读取   |
| `IOUtils.toString(inputStream)` 配合文件流 | Commons IO 转字符串 |
| `getResourceAsStream(path)`           | 类路径资源读取         |
| `RandomAccessFile(path, mode)`        | 随机访问文件          |
| `new File(path)` 配合后续读取操作             | 文件对象构造          |

### 局部确认条件

检查 Sink 方法内部：

1. 文件路径是否为硬编码常量 → 硬编码则排除
2. 是否有 `../` 遍历过滤 → 有则降低 confidence
3. 是否有目录/文件白名单校验 → 有则降低 confidence
4. 是否使用了 canonical path 校验 → 有则降低 confidence
5. 路径参数是否来自方法参数 → 来自参数则 confidence 更高

***

## 12. 硬编码敏感信息

**vuln\_type**: `hardcoded_secrets`

> **重点**：本漏洞类型主要关注可用于**伪造认证凭证、绕过鉴权**的密钥/签名硬编码。

**关键模式**:

### JWT / Token 签名密钥（高优先级）

| 模式                                                      | 说明                     |
| ------------------------------------------------------- | ---------------------- |
| `signingKey = "..."`                                    | JWT 签名密钥               |
| `secretKey = "..."`                                     | JWT/Token 密钥           |
| `Jwts.builder().signWith(...)` 中的硬编码密钥                  | JJWT 签名                |
| `JwtBuilder.signWith(SignatureAlgorithm.HS256, "...")`  | JJWT HS256 密钥          |
| `Algorithm.HMAC256("...")`                              | Auth0 java-jwt 密钥      |
| `Algorithm.HMAC384("...")` / `Algorithm.HMAC512("...")` | Auth0 java-jwt 密钥      |
| `NimbusJwtDecoder` 配合硬编码密钥                              | Spring Security JWT    |
| `MacSigner("...")`                                      | Spring Security MAC 签名 |
| `new SecretKeySpec(bytes, "HmacSHA256")` 中 bytes 为常量    | 通用 HMAC 密钥             |
| `Keys.hmacShaKeyFor("...".getBytes())`                  | JJWT 0.10+ 密钥          |

### 加密/签名密钥

| 模式                                                    | 说明        |
| ----------------------------------------------------- | --------- |
| `private_key = "..."`                                 | RSA/EC 私钥 |
| `AES_KEY = "..."` / `DES_KEY = "..."`                 | 对称加密密钥    |
| `new SecretKeySpec("...".getBytes(), "AES")`          | AES 密钥构造  |
| `Cipher.getInstance("AES").init(mode, key)` 配合硬编码 key | 加密初始化     |
| `HMAC_SECRET = "..."`                                 | HMAC 签名密钥 |

### 认证凭证

| 模式                                                    | 说明                                       |
| ----------------------------------------------------- | ---------------------------------------- |
| `shiro.rememberMe.key = "..."`                        | Shiro RememberMe 密钥（可伪造 Cookie 反序列化 RCE） |
| `setCipherKey(Base64.decode("..."))`                  | Shiro 密钥设置                               |
| `spring.security.oauth2.client.client-secret = "..."` | OAuth2 Client Secret                     |
| `token = "..."` 或 `accessToken = "..."`               | 硬编码 Token                                |
| `apiKey = "..."` / `api_key = "..."`                  | API 密钥                                   |

### 局部确认条件

检查 Sink 方法/类内部：

1. 密钥是否从外部配置文件读取（如 `@Value("${jwt.secret}")`）→ 从配置读取则排除（不是硬编码）
2. 是否在测试类中 → 测试类则排除
3. 字符串长度和复杂度 — 长随机字符串/Base64 编码 = high confidence；短简单字符串 = low
4. 密钥是否用于 JWT 签名或 Token 生成 → 用于签名则 confidence 更高（可伪造凭证绕过鉴权）
5. 是否为 Shiro RememberMe 密钥 → 可直接利用进行反序列化 RCE，confidence = high

