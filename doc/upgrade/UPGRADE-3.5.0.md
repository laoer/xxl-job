# XXL-JOB 升级说明：3.3.1-SNAPSHOT → v3.5.0

> 分支：`sync/upstream-3.5.0`
> 基线：fork 上游基线 `166c2860`（2025-11-29，3.3.0 之后、3.3.1 之前）
> 目标：`upstream/3.5.0-release` = `3bebfc16`（2026-10-09，v3.5.0 正式版）
> 跨度：195 个上游 commit、208 个文件，覆盖 3.3.1 / 3.3.2 / 3.4.0 / 3.4.1 / 3.4.2 / 3.5.0 六个版本

---

## 1. 本次同步做了什么

| 项 | 说明 |
| --- | --- |
| 分支 | 从 `master` 新建 `sync/upstream-3.5.0`，`git merge upstream/3.5.0-release` 合并（保留双亲历史，后续可直接继续 merge 上游） |
| 自定义文件 | `Jenkinsfile`（上游无此文件，无冲突，原样保留）；`xxl-job-admin/Dockerfile`（上游也改过，产生冲突，已保留本仓库的多阶段构建版本） |
| Dockerfile 合入的上游改动 | 仅新增 `EXPOSE 8080`（3.4.1 特性），其余保持本仓库的多阶段构建（`maven:3.9.9-eclipse-temurin-21-alpine` 构建 + `eclipse-temurin:21-jre-alpine` 运行 + 阿里云镜像源 + 时区） |
| Dockerfile 构建修复 | 见 5.4：`-pl xxl-job-admin -am` 只构建调度中心、跳过 sources/javadoc 包、精确选取可执行 jar；另新增根目录 `.dockerignore` 缩减构建上下文 |
| 与上游差异 | 合并提交处与 `upstream/3.5.0-release` **仅差 `Jenkinsfile`、`xxl-job-admin/Dockerfile`**；当前 HEAD 另多出 `.dockerignore`、本说明与 `doc/db/upgrade_3.3.1_to_3.5.0.sql`（`git diff --stat upstream/3.5.0-release..HEAD` 复核，共 5 个文件） |

上游 Dockerfile 的原生做法是把 `target/xxl-job-admin-*.jar` 直接 ADD 进 `eclipse-temurin:17-jre` 镜像；本仓库的 Dockerfile 是「镜像内编译」，两者定位不同，因此以本仓库版本为准。`COPY settings.xml` 依赖 Jenkins 在构建前通过 `maven-settings` 凭据写入工作区根目录（见 `Jenkinsfile` 的 *Prepare Maven Settings* 阶段），构建上下文必须是仓库根目录。

**构建验证**（本机已执行，非模拟）：`mvn clean compile` 与 `mvn -DskipTests package` 均为 **BUILD SUCCESS**（JDK 21 / Maven 3.8.4，7 个模块全绿），产物 `xxl-job-admin/target/xxl-job-admin-3.5.0.jar` 正常生成。Docker 镜像构建未验证（本机无 docker 命令）。

---

## 2. 兼容性结论（先看这条）

**本次升级不是「滚动替换单个组件」可以完成的，调度中心与执行器必须一起升级到 3.5.0。** 原因：

1. 调度中心 OpenAPI（`/api/*`）新增校验：请求头 **`XXL-JOB-ACCESS-TOKEN` 与 `XXL-JOB-APPNAME` 都必填**，且 Token 按执行器 AppName 到 `xxl_job_group.access_token` 里比对；旧执行器只发 Token、不发 AppName → 注册/回调全部被拒。
2. 执行器侧（`EmbedServer`）同样新增校验：`accessToken`、`appname` 任一为空即拒绝；旧调度中心不发 `XXL-JOB-APPNAME` → 触发、心跳、终止、查日志全部失败。
3. 回调报文由 `List<CallbackRequest>` 改为单条 `CallbackRequest`（`HandleCallbackRequest` 更名 `CallbackRequest`），新旧报文互不兼容。
4. 数据库侧 `xxl_job_group.title` → `name`、`xxl_job_info.job_desc` → `name`，旧版调度中心的 mapper 仍按旧列名查询，**改名后查询直接报 `Unknown column`**，升级只能单向、不能新旧并行。

→ 建议按第 7 节的时间窗方案执行：停调度 → 备份 + 迁移 SQL → 发布新调度中心 → 逐个发布执行器。

---

## 3. 数据 SQL 变更

可直接执行的脚本见 **[`doc/db/upgrade_3.3.1_to_3.5.0.sql`](./db/upgrade_3.3.1_to_3.5.0.sql)**（生产可执行版：含 §0 升级前自检、大表 DDL 合并、token 直写生产值 `xxl-job-xy`）。脚本内容来自上游 3.4.0 / 3.5.0 两个版本的官方升级说明（`doc/XXL-JOB官方文档.md` 第 7.44、7.47 节），并按**本仓库当前库结构**做了对齐与补充；3.2.0 与 3.3.1-SNAPSHOT 的库结构经比对完全一致，因此同一份脚本也适用于 3.2.0 生产库。

### 3.1 必做变更一览

| 表 | 变更 | 目的 / 影响 | 大表风险 |
| --- | --- | --- | --- |
| `xxl_job_group` | 新增 `access_token varchar(255)` | 执行器维度 Token 落库（替代全局 `xxl.job.accessToken`） | 小 |
| `xxl_job_group` | `title` → `name`，长度 12 → 64 | 3.5.0 数据模型标准化；执行器名称上限 64 | 小 |
| `xxl_job_group` | 新增唯一索引 `i_app_name(app_name)` | AppName 唯一化（UI 不再允许重复） | 小，执行前需查重 |
| `xxl_job_info` | `job_desc` → `name` | 字段标准化，OpenAPI 入参同步改名 | 小 |
| `xxl_job_info` | `executor_param` `varchar(512)` → `TEXT` | 任务参数最长 2048 字符 | 中 |
| `xxl_job_registry` | `id` `int` → `bigint` | 防大规模执行器集群注册溢出 | 中（重建表） |
| `xxl_job_log` | `executor_param` `varchar(512)` → `TEXT` | 同上 | **大** |
| `xxl_job_log` | 新增 `i_job_group(job_group)`，删除 `I_jobid_jobgroup` | 调度日志按执行器维度查看/查询 | **大** |
| `xxl_job_log` | 新增 `i_alarm_status(alarm_status)` | 失败告警巡检性能（3.5.0 新告警模型） | **大** |
| `xxl_job_log` | 历史数据回填：`alarm_status=0 AND handle_code=200` → `1` | 避免升级后告警巡检反复扫历史成功日志；单次 1W 条，需循环执行到 0 行 | **大** |
| `xxl_job_group` | 存量行补 `access_token`（脚本写入生产值 `xxl-job-xy`） | 不补则 Token 校验永远失败，执行器无法注册 | 小 |

### 3.2 `alarm_status` 语义变化（需要理解，否则会误判数据）

- 旧：`0-默认、1-无需告警、2-告警成功、3-告警失败`
- 新：`0-默认、**-1=锁定中**、1-无需告警、2-告警成功、3-告警失败`

3.5.0 的失败告警线程（`JobFailAlarmMonitorHelper`）先用 `alarm_status: 0 → -1` 抢锁，再重试/告警，最后落到 `1/2/3`。巡检 SQL 只捞 `alarm_status = 0`，因此**停留在 `-1` 的记录不会被再次扫描**；该值只在 3.5.0 之后才可能出现（进程在锁定期间被杀），排查告警“漏发”时先看有没有 `-1` 遗留（脚本 4.5 给了可选清理语句）。

### 3.3 索引命名

上游把索引名从 `I_xxx` 统一为 `i_xxx`。MySQL 中索引名只是标识，**不改也能跑**；脚本里用 `RENAME INDEX` 对齐命名，仅为了后续与上游建表脚本比对方便（MySQL < 5.7 不支持，可改为 `DROP INDEX` + `ADD INDEX`）。

### 3.4 只增不改的部分（无需 SQL）

- 新表 / 删表 / 删列：**没有**。3.3.1 → 3.5.0 全部是列改名、加列、加索引、改类型。
- 全新部署直接用 `doc/db/tables_xxl_job.sql`（已更新为 3.5.0 版本，新增 `OpenClaw示例任务` 种子任务）。注意该脚本是官方版本，种子数据的 `access_token` 为示例值 `default_token`，生产需自行改成实际值（本项目为 `xxl-job-xy`）。

---

## 4. 配置项变更

### 4.1 调度中心（`xxl-job-admin/src/main/resources/application.properties`）

| 配置项 | 变更 | 说明 |
| --- | --- | --- |
| `server.servlet.context-path` | `/xxl-job-admin` → **`/`** | **访问地址变化**：`http://ip:8080/xxl-job-admin` → `http://ip:8080/`。Nginx/网关、监控探活、书签、文档链接全部要改 |
| `xxl.job.accessToken` | **删除** | 全局 Token 废弃，改由 `xxl_job_group.access_token`（执行器维度）+ 执行器配置 `xxl.job.executor.accessToken` |
| `management.endpoints.web.base-path` | → `management.server.base-path=/actuator` | Actuator 探活路径变为 `http://ip:8080/actuator/*`（原 `/xxl-job-admin/actuator/*`） |
| `xxl.job.schedule.batchsize` | **新增**，默认 `100` | 调度后批量合并更新，高频调度场景显著降低 DB 压力；按 DB 承载调整 |
| `mybatis.mapper-locations` | `classpath:/mapper/*Mapper.xml` → `classpath:/mapper/**/*Mapper.xml` | 源码包结构重构（`admin/business/**`），**若外部覆盖了该配置必须同步改** |
| `spring.web.error.whitelabel.enabled` / `spring.jackson.date-format` | 新增 | 报错页与时间格式；如有自定义错误页配置注意冲突 |
| `spring.mail.*` / `xxl.job.i18n` / `xxl.job.triggerpool.*` / `xxl.job.logretentiondays` | 不变 | — |

> 官方文档 `doc/XXL-JOB官方文档.md` 的 5.1 / 5.10 节仍写着旧的 `xxl.job.accessToken`，属于上游文档滞后；以代码和本节为准（`XxlJobAdminBootstrap` 已无 `xxl.job.accessToken`）。

### 4.2 执行器（`xxl.job.*`，各业务应用自己的配置）

| 配置项 | 变更 | 说明 |
| --- | --- | --- |
| `xxl.job.admin.addresses` | **去掉 context-path** | `http://ip:8080/xxl-job-admin` → `http://ip:8080`（3.4.1 消息中心移除自身前缀） |
| `xxl.job.admin.accessToken` | → **`xxl.job.executor.accessToken`** | 必填，值必须与 `xxl_job_group.access_token` 一致（同一执行器一条记录） |
| `xxl.job.executor.enabled` | 新增，默认 `true` | 3.3.1 起支持关闭执行器初始化（灰度/联调场景） |
| `xxl.job.executor.glueenabled` | 新增，默认 `true` | 3.5.0 执行器维度 GLUE 开关，关闭后只允许 BEAN 模式 |
| `xxl.job.executor.logpath` / `logretentiondays` / `excludedpackage` / `ip` / `port` / `address` | 不变 | 样例中 `excludedpackage` 默认值改为空，仅为样例差异 |
| 代码方式注册 | `XxlJobSpringExecutor#setAccessToken()` 仍有效 | 但语义已变为「本执行器的 Token」，不再是全局 Token |

---

## 5. 其他事项清单

### 5.1 运行时与依赖（破坏性）

- **JDK**：编译目标仍为 **17**，运行需 **17+**；本仓库 Dockerfile 用 21 无问题。
- **Spring Boot 3.5.8 → 4.1.1，Spring 6.2 → 7.0.9**：`xxl-job-core` 的编译期依赖只有 slf4j / netty / gson / groovy / xxl-tool，Spring 相关（`spring-context`）为 `provided`，用到的也仅 `ApplicationContextAware`、`SmartInitializingSingleton`、`MethodIntrospector`、`AnnotatedElementUtils` 等长期稳定 API。因此**执行器侧可以只把 `xxl-job-core` 升到 3.5.0，业务应用不必强行升到 Boot 4**；但因 core 是对 Spring 7 编译的，若业务仍用 Spring 6，请在预发先跑通「handler 扫描 → 注册 → 触发 → 日志」链路。调度中心必须随 Boot 4 一起发布。
- 其他主要升级：`mybatis-spring-boot-starter 3.0.5 → 4.1.0`、`mysql-connector-j 9.5.0 → 26.7.0`、`netty 4.2.7 → 4.2.19`、`groovy 5.0.2 → 6.0.0`、`xxl-sso 2.2.0 → 2.4.1`、`xxl-tool 2.3.2 → 2.5.2`、`gson 2.13.2 → 2.14.0`、`junit 6.0.1 → 6.1.3`。
- 项目改为父 POM 统一 `dependencyManagement`，子模块不再写版本号——**如有自己的分支补丁改过子模块版本号，合并后需重新核对**。
- `xxl-sso` 升级可能影响登录态（Cookie/会话策略），升级后用户可能需要重新登录；默认账号仍为 `admin/123456`。

### 5.2 OpenAPI 调用方（运维脚本 / 自研平台）

- URL 前缀变化：`http://ip:8080/xxl-job-admin/api/xxx` → `http://ip:8080/api/xxx`。
- 必须同时带两个头：`XXL-JOB-ACCESS-TOKEN: <该执行器的 token>`、`XXL-JOB-APPNAME: <执行器AppName>`。
- 新增任务管理能力：`addJob`、`updateJob`、`removeJob`、`startJob`、`stopJob`、`triggerJob`（报文 DTO 见 `xxl-job-core/src/main/java/com/xxl/job/core/openapi/admin/dto`，`jobDesc` 字段已改名 `name`）。
- 回调报文由数组改单条（仅影响自研执行器/自研 Admin 的对接方）。

### 5.3 功能与行为变化（按需关注）

- **优雅停机**（3.3.2）：调度中心停机等待时间轮清空；执行器停机先停止接收新任务并等待运行中任务结束 —— 发布时的停机窗口与超时设置需相应放宽。
- **调度批量合并**（3.4.0）：调度结果批量写库（`xxl.job.schedule.batchsize`），DB 写入模式变化，慢查询监控口径会变。
- **执行器注册表主键 bigint**（3.4.0）：配合执行器大规模集群。
- **固定间隔（FIX_RATE）调度**、**Cron 解析 `L`**、**一致性哈希路由**均有修复/重构。
- **PowerShell GLUE**（3.4.2）：改用 **PowerShell 7（`pwsh`）** 执行，执行器所在机器必须安装 PowerShell 7+，否则该类型任务直接失败。
- **执行器删除**会连带清理注册表数据（3.3.1）。
- **UI**：任务/执行器「名称」字段标准化；调度日志支持按执行器维度查看；任务与日志列表下拉框支持模糊搜索；弹框在 iframe 中自适应居中。截图类文档、自动化 UI 脚本可能受影响。
- **XSS 修复**（3.4.1：任务编辑等页面）与**RollingLog 越权修复**（3.4.2）：如有前端定制或日志代理，请回归。

### 5.4 Docker / CI 相关

- 上游新增 `docker/docker-compose.yml` + `docker/.env`（MySQL 8.4 + admin + 执行器样例一键启动）。
  ⚠️ **直接使用会失败**：compose 里 admin 的构建上下文是 `../xxl-job-admin`，而本仓库 Dockerfile 是「仓库根目录多阶段构建」（需要父 POM、`xxl-job-core`、以及 Jenkins 注入的 `settings.xml`）。若要使用 compose，请把 admin 的 `build.context` 改为 `..`、`dockerfile` 改为 `xxl-job-admin/Dockerfile`，或直接使用镜像 `image:` 方式。
- 上游把样例 Dockerfile 基础镜像换成 `eclipse-temurin`，本仓库 `xxl-job-admin/Dockerfile` 已是 temurin 21（alpine），无需跟随。
- `.gitignore` 补充了 `**/target/`、`node_modules/`、`/dist/`、`package-lock.json`、`.claude`、`.specify`、`specs` 等规则（上游为 AI 友好性重构加入），对本仓库无副作用。
- 版本号：`pom.xml` 已变为 `3.5.0`（正式版，非 SNAPSHOT）；`Jenkinsfile` 用 `BUILD_NUMBER` 打 tag，无需改动。

#### 镜像构建修复（本次已改 Dockerfile）

父 POM 的 `release` profile 默认激活，把 `maven-source-plugin` / `maven-javadoc-plugin` 绑到了 `package` 阶段，所以 `mvn package` 会在 `xxl-job-admin/target/` 下同时产出 3 个 jar：

```
xxl-job-admin-3.5.0.jar  xxl-job-admin-3.5.0-sources.jar  xxl-job-admin-3.5.0-javadoc.jar
```

而 Docker「通配符匹配到多个源文件时，目标必须是目录」——原来的 `COPY --from=build .../xxl-job-admin-*.jar /app.jar` 在 buildkit 下会直接报错。旧版本（3.3.1-SNAPSHOT）的父 POM 同样绑定了这两个插件，所以这是**合并前就存在的隐患，与本次升级无关**，但会让 Jenkins 出不了镜像。

新 Dockerfile 做了四处调整（运行镜像的内容与行为等价）：

1. 构建命令限定模块并跳过无关产物：
   ```dockerfile
   RUN mvn -s /root/.m2/settings.xml -B -ntp \
           -pl xxl-job-admin -am \
           clean package \
           -Dmaven.test.skip=true \
           -Dmaven.source.skip=true \
           -Dmaven.javadoc.skip=true
   ```
   `-pl xxl-job-admin -am` 只构建父 POM + core + admin（样例模块不再参与，构建更快、也不会被样例模块的第三方依赖影响）；`-Dmaven.source.skip/-Dmaven.javadoc.skip` 让 `target/` 下只留可执行 jar。
2. jar 选取改为显式脚本，再 `COPY --from=build /app.jar`，彻底避开通配符多文件问题（即使将来 POM 变回产出 sources/javadoc 也不会挂）：
   ```dockerfile
   RUN set -eu; \
       jar="$(ls -1 xxl-job-admin/target/xxl-job-admin-*.jar \
           | grep -v -e '-sources\.jar$' -e '-javadoc\.jar$' \
           | head -n 1)"; \
       test -n "$jar"; \
       cp "$jar" /app.jar
   ```
3. 新增根目录 `.dockerignore`：排除 `.git`、`**/target`、`doc`、`docker` 等，构建上下文从 ~274MB 降到 ~7.5MB（Jenkins 的 buildx 需要上传上下文，这一步对构建时长影响明显）。已被排除的内容不参与编译；`settings.xml`、`pom.xml`、各模块 `pom.xml` 均保留。
4. 适配「x86 构建机 + `--platform linux/arm64`」的跨平台构建（见下一条）。

#### 跨平台构建：`exec /bin/sh: exec format error`

Jenkins 用 `docker buildx build --platform linux/arm64` 出 arm64 镜像。如果构建机是 x86_64 且没有安装 QEMU binfmt，buildx 会把 arm64 的基础镜像拉下来，但**无法执行**其中任何进程，于是任何在目标平台上的 `RUN` 都会报：

```
exec /bin/sh: exec format error
```

这跟 Dockerfile 内容无关（原来的 `apk add tzdata`、`ln -sf` 也会踩到），根因是构建机缺少 arm64 用户态模拟。有两种解法：

- **解法 A（改 Dockerfile，本次已采用，不需要动 Jenkins 机器）**：约定「构建阶段跑原生平台、运行阶段零 `RUN`」：
  - 构建阶段固定 `FROM --platform=$BUILDPLATFORM maven:...`，编译在构建机原生架构上执行（jar 与架构无关）；
  - 运行阶段的 `apk add tzdata` 挪到构建阶段完成，再 `COPY --from=build` 把 `zoneinfo` / `/etc/localtime` / `/etc/timezone` 复制进运行阶段；
  - 运行阶段只剩 `FROM/ARG/ENV/COPY/EXPOSE/ENTRYPOINT`，**不执行任何目标平台进程**，因此无 QEMU 也能产出架构正确的 arm64 镜像。

- **解法 B（改构建机，一劳永逸）**：给构建机装 binfmt，之后任何 Dockerfile 都能跨架构构建：
  ```bash
  docker run --privileged --rm tonistiigi/binfmt --install arm64
  docker run --rm --platform linux/arm64 eclipse-temurin:21-jre-alpine java -version   # 验证
  ```
  装完 QEMU 后，解法 A 的写法依然可用（只是少跑了几步），也可以把运行阶段的 `RUN apk add tzdata` 改回去。

判断当前构建机状态：

```bash
uname -m                                                                  # 构建机架构
docker run --rm --platform linux/arm64 alpine uname -m                      # 报 exec format error = 缺 binfmt
docker buildx imagetools inspect eclipse-temurin:21-jre-alpine              # 确认该 tag 有 linux/arm64
```

> 注意：解法 A 依赖「基础镜像的 arm64 variant 确实存在」。如果 `imagetools inspect` 看不到 `linux/arm64`，说明镜像源（私有仓库/加速器）缺架构，需要换镜像或换源；否则会构建成功但运行期报错。

时区配置也顺手合并成一段（原来 `tzdata` 与时区符号链接设置重复了两次，结果等价）。`ENTRYPOINT`、`EXPOSE 8080`、`PARAMS/JAVA_OPTS/LOG_HOME` 变量用法保持原样，Jenkinsfile 无需改动。

### 5.5 AI 执行器样例（仅样例，非必须）

- 新增 `openClawJobHandler`（OpenClaw 集成），`spring-ai 2.0.1`、`dify-java-client 1.7.0`；
- 种子数据新增「OpenClaw示例任务」（全新部署时生效，升级环境不会自动插入）。

---

## 6. 代码层面的结构变化（自研改造需注意）

- 调度中心包结构重组：`com.xxl.job.admin.controller.biz.*` → `com.xxl.job.admin.business.controller.*`，`mapper` → `business.mapper`，`scheduler` → `business.scheduler`，新增 `framework.*`（登录、I18N、工具等）。
- 执行器侧线程类改为 `*Helper` 形式（`ExecutorRegistryThreadHelper`、`TriggerCallbackThreadHelper`、`JobLogFileCleanThreadHelper`），底层线程统一为 `xxl-tool` 的 `CyclicThread`；旧的三个 Thread 类已删除。
- `xxl-job-core` 新增 `openapi.admin` / `openapi.executor` 包，旧的 `util.deprecated.*`（`AdminBizClient`、`ExecutorBizClient`、`XxlJobRemotingUtil`）保留为注释状态。
- **本 fork 在这两个包之外没有业务代码改动（只有 Jenkinsfile / Dockerfile），因此合并无额外适配成本。**

---

## 7. 推荐升级时序（含窗口方案）

```
T0 前：
  1) 备份数据库；在预发环境完整演练第 3 节 SQL + 新版本发布；
  2) 统计 xxl_job_log 行数，评估 ALTER 耗时（TEXT 变更 + 索引重建）；
  3) 确认所有执行器的 Token 方案（沿用现网统一值 `xxl-job-xy`，或按执行器分配新 Token）；
  4) 准备 Nginx/网关改动：/xxl-job-admin 前缀下线，根路径反代到 admin；探活改 /actuator/health。

T0（维护窗口）：
  5) 停止调度中心；所有执行器停止调度（或接受窗口内的失败日志）；
  6) 执行 doc/db/upgrade_3.3.1_to_3.5.0.sql（含 alarm_status 回填循环、access_token 回填）；
  7) 发布新版调度中心，验证：登录 → 执行器列表有 name 字段 → 手动录入/自动注册正常；
  8) 逐个发布执行器（升级 xxl-job-core 到 3.5.0 + 改配置项 + Token 对齐），观察注册成功；
  9) 全量恢复调度，抽查 CRON/FIX_RATE/GLUE/分片/失败告警。

T1 后：
 10) 观察 1 个调度周期；核对告警、日志滚动、优雅停机日志；
 11) 清理旧的 I_jobid_jobgroup 等历史索引（脚本已含）；
 12) 若使用 OpenAPI 平台，切换 URL 与新请求头。
```

### 回滚

- 数据库变更不可逆（列改名）。回滚 = 恢复 DB 备份 + 回退到旧镜像/旧 core；旧版本与新库结构不兼容，因此回滚必须在窗口内恢复备份，不能只回退应用版本。
- 建议窗口内在**新库副本**上先跑一遍发布验证，再切换生产库，缩短回滚半径。

---

## 8. 验证清单

- [ ] `git diff upstream/3.5.0-release..HEAD --stat` 只有 `Jenkinsfile`、`xxl-job-admin/Dockerfile` 与本升级说明/脚本（4 个文件）
- [ ] `mvn clean package -Dmaven.test.skip=true` 通过（JDK 17+）
- [ ] Jenkins 上 `docker buildx build --platform linux/arm64 --file xxl-job-admin/Dockerfile . --load` 成功，镜像内 `/app.jar` 为可执行 jar（非 sources/javadoc）
- [ ] 产出的镜像在目标 arm64 机器上能起来（`docker run --rm <image> java -version` 能打印 arm64 的版本）
- [ ] SQL 脚本执行后 4 张表的 `SHOW CREATE TABLE` 与 `doc/db/tables_xxl_job.sql` 一致
- [ ] `xxl_job_group.access_token` 无 NULL/空
- [ ] 新调度中心访问根路径、Actuator `/actuator/health` 正常
- [ ] 执行器注册成功（`xxl_job_registry` 有数据、UI 执行器在线）
- [ ] 触发一次任务，`xxl_job_log` 正常写入且告警状态流转正确
- [ ] 失败任务告警可发送（邮件配置回归）
- [ ] GLUE 任务、PowerShell 任务（如有）执行正常

---

## 9. 待确认/可选项

1. **Token 策略**：当前统一使用 `xxl-job-xy`（与现网执行器配置一致，改动最小）；后续如需隔离，可在 UI「执行器管理」逐个改成独立 Token，并同步对应执行器的 `xxl.job.executor.accessToken`。
2. **docker-compose**：是否按 5.4 调整 `build.context` 以适配本仓库 Dockerfile，或干脆只用 Jenkins 出的镜像。
3. **是否把 `sync/upstream-3.5.0` 推送到 origin 并发 PR**（当前仅本地分支，未推送）。
4. 上游 `master` 已是 `3.5.1-SNAPSHOT`（含 3.5.1 开发中的日志保留策略重构），本次按需求只同步到 v3.5.0 正式版。
5. Dockerfile 的 jar 选取多文件问题、样例模块参与构建问题已在本次修掉（见 5.4）；如果你希望构建时**连样例模块一起编译**（例如想用同一个镜像验证样例），把 `-pl xxl-job-admin -am` 去掉即可。
