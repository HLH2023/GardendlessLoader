# 08 接力日志

> 只追加，不改写历史。Hermes 记录 dispatch/关闭，agent 记录接受/进行/阻塞/交付。
> 机器可读版本在 `state.json`，这里是人读的时间线。

## 2026-10-25 / Hermes / dispatch R-20261025-01

- **背景**：hlh.16 发布完成。本轮把 Windows「下载资源」形态真正打通（自写流式 ZIP），
  并修掉一批状态机与令牌生命周期的缺陷。251 项测试全绿。
- **关键发现（留给后继者避免重复踩）**：
  1. `package:archive` 的 `decodeStream` 会把整包内容留在内存（1.31 GB 包 → 峰值 1600 MB），
     桌面解压必须走 `lib/src/services/streaming_zip.dart`（同包峰值 294 MB、6.9 s）。
  2. 桌面 `prepareDesktopGame()` 早期没有启动互斥，连点会起两个服务器 + 两个窗口。
  3. 在线形态曾在 `GameSession` 构造**之后**才拉服务器清单，导致心跳上报旧游戏版本。
  4. 原生心跳 `stop()` 曾在主线程同步发网络请求（`onDestroy` 最长阻塞 10 s，ANR 风险）。
  5. 令牌被 401 拒绝后不会清登录态，云功能一直静默失败。
  6. 存储迁移没有日志，断电会留下「搬一半」的半残状态；也没有空间预检。
  7. 服务端 `safe_user()` 会把用户名里的 `.`/`-` 剥掉，与 `/save` 建目录用的原始名不一致，
     导致管理员查/删不到这类用户的存档。
  8. Windows 构建机删 `build/` 必须连 `.dart_tool/` 一起删，否则 `MSB3037/3073`。
- **交付**：`.handoff/` 接力包（协议、状态、7 篇文档、短提示词、agent 技能、校验器）。

## 2026-10-25 / Hermes / 交接包自检

- `bash tools/handoff.sh verify` 结果见下一条（首次建立后由 Hermes 跑一遍并记录）。

<!-- 以下是 agent 的回执区，按 PROTOCOL.md 第 3 节格式追加 -->

## R-20261025-01 / orchestrator(opencode) / 2026-10-25T14:17+08:00

- status: review
- readBack: { taskTitle: "hlh.17：安卓端到端验收 + 资源包管理 UI 收口 + 已知缺陷清单清零", versionBefore: "0.9.0-hlh.16 (90016)", testsBaseline: "251 项（142 服务端 + 109 客户端）" }
- 版本: `0.9.0-hlh.16+90016` → `0.9.0-hlh.17+90017`
- 测试: 286 项（145 服务端 + 141 客户端）；实测 282 通过 / 4 失败（4 条全部因线上未部署，源码已修）
- 产物: APK 58,601,820 B `3008116e…`（v1+v2+v3 三签）；Windows zip 190,000,316 B `ce8909ef…`

### 缺陷逐条：现象 → 根因 → 改法 → 断言

#### B-16 存档 API 偶发 501（基线本来就红，本次新发现）
- **现象**：`test-cloud-saves.sh` 的「吊销后公网同样失效」稳定拿到 501 而不是 401；
  响应体是 `Unsupported method ('{"id":"3c46…"}GET')`。此前文档把 501 一律归因为
  「测试脚本 URL 拼装问题」。
- **根因**：`do_POST` 先 `_ident()` 再 `_body()`。未授权请求直接回 401，请求体留在
  HTTP/1.1 keep-alive 连接里；下一个请求复用该连接时，`http.server` 把残留 JSON 当成
  请求行，方法变成 `{"id":…}GET` → 501。同一个 `TOKEN` 下测试才会复现，手工单发不会。
- **改法**：新增 `_read_body_bytes()`，先读完请求体再鉴权；超过上限时也读完丢弃并
  `close_connection = True`；`do_POST` 调整顺序。
- **断言**：`test-cloud-saves.sh`「未授权 POST 不污染 keep-alive 连接」——同一条 socket
  上 POST(无身份，带 body) 后 GET，必须是 401。旧代码 → 501，新代码 → 401
  （用临时实例 18090 实测）。

#### B-01 安卓在线形态不可诊断 / 401 不退登
- **现象**：在线游玩时心跳完全静默，服务端是否登记无法判断；令牌被吊销后游戏白屏，
  启动器仍显示「已登录」，所有云功能静默失败。
- **根因**：`OnlineSessionHeartbeat.post()` 吞掉所有结果（连 statusCode 都没读）；
  401 没有跨进程通道——游戏期间 Flutter 引擎已销毁，Dart 侧的 `_handleTokenRejected`
  根本没机会运行。
- **改法**：心跳回调 `(phase, statusCode, durationMs, error)`，每次上报写
  `game.heartbeat / heartbeat_sent|heartbeat_failed`；401/403 停发并上报一次；
  资源代理 401 也在首屏就上报；`GameActivity` 用既有 `game_exit_result.json` 通道
  写 `reason=tokenRejected` 退回启动器；Dart 启动时消费该原因 → `signOutAccount()`。
- **断言**：`tool/check_game_host_contract.dart` 双向比对 Kotlin/Dart 枚举
  （`tokenRejected` 忘了同步会立刻红）、`GameActivity` 必须引用 `TOKEN_REJECTED`、
  `exitResultRequiresSignOut` 的真值表 4 条。

#### B-02 资源包管理：删除入口不存在，门禁确有漏洞
- **现象**：原条目假设有「安装列表/切换/删除」UI，实际没有；真正的风险在「迁移/切形态
  只查内存门禁」。断电后 `isImporting=false` 但 `transactionState` 还停在
  extracting/validating/readyToActivate，此时迁移会把半成品槽搬走。
- **根因**：持久化事务状态只在启动恢复用，没有被破坏性入口当门禁；`cleaningOldSlot`
  语义没区分（新槽已可用，只是旧槽待清）。
- **改法**：`resourceTransactionBusy(state)` 统一判定（idle/cleaningOldSlot 不忙，其余忙），
  迁移、切形态、导入三处接入；迁移的拒绝文案明确要求重启完成恢复。
- **断言**：`tool/check_storage_migration.dart` 遍历全部 `TransactionState` 的 7 条
  忙判定（今天 62 项）。UI 双端一致性由「同一份字符串 + 同一套禁用判定」保证，
  真机按 `docs/acceptance-android.md` 第 4 节复核。

#### B-06 管理页后台仍每 5 s 轮询
- **现象**：标签页切到后台，`setInterval(refresh, 5000)` 继续发请求。
- **根因**：定时器只在「自动刷新」勾选框变化时增删，没有监听页面可见性。
- **改法**：抽 `startAuto/stopAuto`，`visibilitychange` 隐藏即停、可见时先 `refresh()`
  再恢复；用户手动关掉自动刷新时不擅自恢复。
- **断言**：`test-cloud-saves.sh`「管理页后台标签页暂停轮询（visibilitychange）」。

#### B-07 历史存档「设备未知」
- **现象**：93 个早期存档版本没有 `device` 字段，管理页只显示「设备未知」，无法区分
  「历史数据缺失」和「设备信息异常」。
- **根因**：`deviceBadge(null)` 的兜底文案没有语义，也没有说明为什么不回填。
- **改法**：显示「历史设备（未记录）」并加 tooltip；不回填、不猜测。
- **断言**：`test-cloud-saves.sh`「早期无 device 字段的存档显示为历史设备」。

#### B-09 `.ps1` 编码陷阱无自动化
- **现象**：PowerShell 5.1 读无 BOM 的中文注释会按 ANSI 解码，构建报语法错误，
  而 Linux 侧一切正常。
- **根因**：只写在文档里的约定，没有任何机器检查。
- **改法**：`tools/handoff.sh verify` 新增「Windows 构建脚本编码」一节。
- **断言**：`bom-ok crlf=70 lf_only=0`（当前值）；无 BOM 或出现纯 LF 直接失败。

#### B-17 desktop-zip fixture 说明错误
- **现象**：按 `docs/06-testing.md`「任意带嵌套目录的 ZIP」生成 fixture，
  套件报「解压返回文件数 2」并在 `big.length()` 抛 `PathNotFoundException`。
- **根因**：脚本硬编码期望 3 个条目（含 3 MiB 的 `assets/big.bin`）+ 1 个越界条目，
  文档写的是「任意 ZIP」。
- **改法**：把精确 fixture 生成代码写进文档。
- **断言**：按文档生成后 11 项全绿（本轮实测）。

### 交付说明
- 客户端：`flutter analyze` 干净；4 个客户端套件 141 项全绿。
- 服务端：`save-api/server.py` + `admin.html` 已改，新增 3 条断言；
  线上容器与 `/var/www` 静态页未部署，因此 cloud-saves 实测 **54/4**（145 项其余 87 全绿）。
  4 条失败均为「源码已修、部署滞后」，不是未修。
- 产物已落 `dist/`（gitignore），发布与部署动作见 `needsHermes`。

### verify 输出（原样）

```
== 文件齐备 ==
  ok   存在 .handoff/PROTOCOL.md
  ok   存在 .handoff/HANDOFF.md
  ok   存在 .handoff/state.json
  ok   存在 .handoff/docs/01-architecture.md
  ok   存在 .handoff/docs/02-branches.md
  ok   存在 .handoff/docs/03-versioning.md
  ok   存在 .handoff/docs/04-build.md
  ok   存在 .handoff/docs/05-deployment.md
  ok   存在 .handoff/docs/06-testing.md
  ok   存在 .handoff/docs/07-backlog.md
  ok   存在 .handoff/docs/08-handoff-log.md
  ok   存在 .handoff/prompts/01-start.md
  ok   存在 .handoff/prompts/02-return.md
  ok   存在 .handoff/skills/gardendless-dev/SKILL.md

== state.json 结构 ==
  ok   OK review suites= 8 total= 286

== 回执完整性 ==
  ok   OK 2 条回执字段完整

== 敏感信息扫描（.handoff + AGENTS.md + tools/handoff.sh） ==
  ok   未发现服务器地址/令牌字面量

== 源码敏感扫描（lib/tool/android/.github/pubspec/docs） ==
  ok   源码与配置未出现服务器地址/令牌

== AGENTS.md 只放持久信息 ==
  ok   未出现版本号/任务号/测试数字/哈希等易变事实

== Windows 构建脚本编码 ==
  ok   build-windows.ps1 为 UTF-8 BOM + CRLF（bom-ok crlf=70 lf_only=0）

== 短提示词长度 ==
  ok   01-start.md 共 9 行（≤14）

== 技能安装 ==
  ok   已装入 opencode 全局 skills

结果：22 通过 / 0 失败 / 0 警告
```

### needsHermes（本轮未做的副作用动作）
1. `cd /home/hlh/pvzge && bash tools/deploy-save-api.sh` —— 让 `server.py` 的读体顺序修复生效；
2. `APP_SYNC_OUT_DIR=/tmp/pvz-static python3 tools/make-app-sync.py` + nsenter 落地
   `/var/www/pvzge-save/` —— 让管理页的 visibilitychange / 历史设备文案生效；
3. 重跑 `bash tools/test-cloud-saves.sh`，预期 **58 / 0**（当前 54 / 4）；
4. `bash tools/publish-apk.sh dist/gardendless-loader-0.9.0-hlh.17.apk --version 0.9.0-hlh.17`，
   再 `gh release create v0.9.0-hlh.17` 上传 `dist/` 两个产物；
5. 复核并推送服务端仓库三处改动；
6. 发布后补 `state.json.release.releaseUrl` 并把 `pendingPublish` 置 false。
7. 把 `HANDOFF.md` 第 2 节更新到 hlh.17（版本、能力矩阵、基线 286），并勾选第 4 节验收项。

## R-20261025-01（追加）/ orchestrator(opencode) / 2026-10-25T14:41+08:00

- status: review
- 版本: `0.9.0-hlh.17+90017` → `0.9.0-hlh.18+90018`
- 测试: 334 项（162 服务端 + 172 客户端）；实测 321 通过 / 4 失败 / 1 跳过（均为线上未部署）
- 产物: APK 58,618,208 B `0d504deb…`（v1+v2+v3）；Windows zip 190,006,698 B `1bd1f647…`

### 缺陷逐条：现象 → 根因 → 改法 → 断言

#### B-05 历史存档保留 1000 → 300
- **现象**：每个存档键最多堆 1000 份历史，磁盘长期膨胀；且需要确认裁剪不会跨版本误删。
- **根因**：上限写死在 `server.py` 默认值与 compose 环境变量里；裁剪逻辑本身是按目录做的，
  但没有断言保护「按版本隔离」和「删旧不删新」这两个前提。
- **改法**：默认与 compose 都改为 300；历史目录仍为
  `by-version/<gv>/.history/<key>`，裁剪只在该目录内进行；排序键 `(ts, seq)` 保证同一秒的
  `ts-n` 按序号保留最新的。
- **断言**：`test-save-versions.sh` 第 8.5 节 8 条：300 份上限、边界 1104 删/1105 留、
  同秒序号保留、1.6.2 不受 1.6.1 影响、同版本另一个键不受影响、非历史文件不参与。

#### B-04 令牌对游戏 JS 可见
- **现象**：注入的 `__sync_app.js` 里直接写设备令牌，恶意第三方资源包可读走长期凭据。
- **根因**：存档桥必须让页面 JS 发请求，于是把设备令牌原样注入；而设备令牌还能签发/吊销令牌。
- **改法**：新增 `POST /token/session`（设备令牌换 3 小时会话令牌，不带管理员组、只能读写存档）；
  页面注入会话令牌；原生心跳/在线资源代理改读 0600 的 `__sync_native_token`（长期设备令牌），
  避免会话过期把在线登记一起带走；吊销设备令牌连带删除其会话。
- **断言**：`test-cloud-saves.sh` 8.6 节（可读写、不能签发/吊销、列表不显示、过期 401、吊销连带失效）
  + `check_game_host_contract.dart`（响应解析、原生凭据文件 Dart/Kotlin 同名、原生优先读宿主凭据）。
- **残留**：页面仍能拿到会话令牌（这是 Web 存档桥的固有形态）；影响面从「账号凭据」收窄到
  「3 小时内读写本人存档」。

#### B-08 Windows 自更新
- **现象**：Windows 只能手动下载替换，没有任何校验。
- **根因**：更新链路只实现了 APK（aapt badging + 系统安装器）；Windows 没有对应清单与替换机制。
- **改法**：服务端新增 `publish-windows.sh`（写 `win/manifest.json`，versionCode 回退拒绝、保留 3 个历史）；
  客户端新增桌面端更新卡片（检查/下载/sha256 校验/打开目录/退出并自动更新）；替换由生成的
  PowerShell 脚本执行：等进程退出 → 解压校验 exe → 整目录备份 → robocopy → 失败回滚 → 重启 → 清理；
  安装目录不可写时拒绝启动脚本。
- **断言**：`check_update_manifest.dart` 22 条（字段校验、versionCode/版本名判定、文件名防穿越、
  脚本含备份/回滚、BOM+CRLF）；脚本在 Windows 构建机沙盒实测覆盖/保留/清理/退出码 0。

#### B-03 SAF 目录授权（决策：不做）
- **现象**：安卓只能从候选目录选或手填绝对路径，U 盘等特殊目录体验差。
- **根因/约束**：SAF 返回 `content://` 树，而游戏 WebView 需要一个真实文件系统根；
  要支持必须把校验/导入/迁移全部改成 SAF 抽象，属大改造。
- **决定**：不做。候选列表已覆盖「应用外部目录 + 各外置卷的应用目录」，都是真实可写路径；
  收益不足以承担回归风险。
- **改法（可交付部分）**：选择框补充说明文案，告诉用户为什么没有系统选择器、U 盘可手填。
- **断言**：无代码路径变更；真机按 `docs/acceptance-android.md` 第 4 节复核迁移与门禁。

### verify 输出（原样）

```
== 文件齐备 ==
  ok   存在 .handoff/PROTOCOL.md
  ok   存在 .handoff/HANDOFF.md
  ok   存在 .handoff/state.json
  ok   存在 .handoff/docs/01-architecture.md
  ok   存在 .handoff/docs/02-branches.md
  ok   存在 .handoff/docs/03-versioning.md
  ok   存在 .handoff/docs/04-build.md
  ok   存在 .handoff/docs/05-deployment.md
  ok   存在 .handoff/docs/06-testing.md
  ok   存在 .handoff/docs/07-backlog.md
  ok   存在 .handoff/docs/08-handoff-log.md
  ok   存在 .handoff/prompts/01-start.md
  ok   存在 .handoff/prompts/02-return.md
  ok   存在 .handoff/skills/gardendless-dev/SKILL.md

== state.json 结构 ==
  ok   OK review suites= 9 total= 334

== 回执完整性 ==
  ok   OK 3 条回执字段完整

== 敏感信息扫描（.handoff + AGENTS.md + tools/handoff.sh） ==
  ok   未发现服务器地址/令牌字面量

== 源码敏感扫描（lib/tool/android/.github/pubspec/docs） ==
  ok   源码与配置未出现服务器地址/令牌

== AGENTS.md 只放持久信息 ==
  ok   未出现版本号/任务号/测试数字/哈希等易变事实

== Windows 构建脚本编码 ==
  ok   build-windows.ps1 为 UTF-8 BOM + CRLF（bom-ok crlf=70 lf_only=0）

== 短提示词长度 ==
  ok   01-start.md 共 9 行（≤14）

== 技能安装 ==
  ok   已装入 opencode 全局 skills

结果：22 通过 / 0 失败 / 0 警告
```

### needsHermes（追加）
1. `bash tools/deploy-save-api.sh` —— 会话令牌 + 历史保留 300 生效；
2. 重新生成 `app-sync.js` / `app-ui.js` / `app-admin.html` 并落地；
3. `bash tools/publish-windows.sh dist/gardendless-loader-0.9.0-hlh.18-90018-windows-x64.zip --version 0.9.0-hlh.18`；
4. 部署后重跑 `test-cloud-saves.sh`，预期 **67 / 0**（当前 54 / 4 / 1 跳过）；
5. 发布 APK + `gh release create v0.9.0-hlh.18`；
6. 复核并推送服务端仓库 7 处改动；更新 `HANDOFF.md` 到 hlh.18。

> 数字更正：提交 `abc5670` 的正文写「服务端 162 项中 158 项绿」，实际是
> **149 项通过 / 4 项失败 / 9 项跳过（1 个 SKIP 块）**；162 是设计总数，
> 部署后 cloud-saves 补齐 9 条即为 162/0。回执里的 `tests` 字段已按
> `321 通过 + 4 失败 + 9 跳过 = 334` 对齐。

## R-20261025-01（部署与发布）/ orchestrator(opencode) / 2026-10-25T14:55+08:00

- status: review
- 版本: `0.9.0-hlh.18+90018`（已部署、已发布）
- 测试: 334 项全绿（162 服务端 + 172 客户端），`cloud-saves` 由 54/4/1skip 转为 **67 / 0 / 0**
- Release: https://github.com/HLH2023/gardendless-app/releases/tag/v0.9.0-hlh.18

### 执行了什么
1. **部署存档 API**：`deploy-save-api.sh` 重建 `pvzge-save`，healthz / `/load` / `/save` 冒烟通过；
   容器内 `HISTORY_KEEP=300`，`/app/server.py` 与源文件 md5 一致（`8e98a186…`）。
2. **落地注入脚本**：重新生成 `app-sync.js` / `app-ui.js` / `app-admin.html` 并用 nsenter 写入
   `/var/www/pvzge-save/`，三份文件与生成件 md5 全部一致。
3. **全量服务端回归**：`test-cloud-saves.sh` 67/0，会话令牌 9 条断言首次真正跑起来并通过。
4. **发布更新通道**：
   - Windows：`publish-windows.sh` → `/var/www/pvzge-res/win/` + `manifest.json`；
   - APK：`publish-apk.sh` → `/var/www/pvzge-res/apk/` + `manifest.json`；
   - 带 Bearer 实测两个清单 200、latest=90018、size/sha 与磁盘一致、zip 下载 200。
5. **创建 Release**：GitHub API 创建 `v0.9.0-hlh.18`（201），上传两个资产（各 201），
   查询结果为 2 个 `uploaded`，大小与本地一致。
6. **推送服务端仓库**：`pvzge/main` 已更新（会话令牌、历史 300、发布脚本、测试）。
7. **更新 HANDOFF**：第 2 节到 hlh.18、能力矩阵与基线；第 4 节验收项全部勾选。

### 数字更正与说明
- 上一轮提交正文的「158 项绿」已在上一条日志更正为 149；本轮部署后服务端 162 项全绿。
- APK 浏览器下载路径最终 200（authentik 登录页），`/version.json` 200。

### 仍未闭环（非 Hermes）
- 安卓真机点击：用户执行，清单在 `docs/acceptance-android.md`。
- Windows 真实安装目录的「退出并自动更新」：首次执行时观察（失败会回滚并重启）。
- 公开仓历史域名清理（B-15）：需要用户决定是否 force-push。

## R-20261025-01（hlh.19 热修）/ orchestrator(opencode) / 2026-10-25T15:20+08:00

- status: review
- 版本: `0.9.0-hlh.18+90018` → `0.9.0-hlh.19+90019`
- 触发：用户在 Windows 安装 hlh.18 后无法打开

### 现象 → 根因 → 改法 → 断言

#### Windows 双击没有界面（P0）
- **现象**：hlh.18 解压后双击 `gardendless_loader.exe`，进程在但不出现界面。
- **根因**：`main()` 第一步调用 `NativeAppLogger.initialize`，该通道
  `io.github.dey410.gardendlessloader/app_logger` 只有 Android/iOS/OHOS 实现；
  Windows 返回 `MissingPluginException`，`runApp` 从未执行。用 SSH 启动并重定向
  stderr 复现到完整堆栈（`NativeAppLogger.initialize` 第 22 行）。
- **改法**：`NativeAppLogger.initialize` 捕获 `MissingPluginException` /
  `PlatformException` / `FormatException`，退回 `InMemoryAppLogger`；`main` 外层
  再加一层 try/catch。日志页仍可看本次会话事件，标记 `persisting=false`。
- **断言**：`check_game_host_contract.dart` 5 条（降级分支、内存快照、main 继续启动、
  会话令牌失败关闭、更新入口拒绝盘符根目录）；Windows 实机启动验证见下。

#### 会话令牌失败回退到设备令牌（P1，安全回归）
- **现象**：`/token/session` 抖动或旧服务端 404 时，页面拿到的是长期设备令牌。
- **改法**：失败即 `return ''`（本次启动不注入存档桥），绝不回退。
- **断言**：`check_game_host_contract.dart` 的「会话令牌失败时不回退到设备令牌」。

#### 存储迁移可把父目录当成目标（P1，数据丢失）
- **现象**：把资源根从 `...\Gardendless` 改到 `...`（父目录）会先删除父目录里同名的
  `downloads` / `settings.json`，再搬入。
- **改法**：`validate()` 同时拒绝「目标在当前目录内」与「目标在当前目录的上级」。
- **断言**：`check_storage_migration.dart` 新增「当前目录的上级目录被拒」（63 项）。

#### Windows 更新脚本带空格路径必失败（P1）
- **现象**：安装在 `Program Files` 时 robocopy 参数被空格拆开，备份失败退出。
- **改法**：`-ArgumentList` 改为显式加引号的字符串；回滚改 `/MIR`；拒绝盘符根目录；
  失败路径清理 stage；残留进程按 `Target + '\'` 边界匹配。
- **断言**：`check_update_manifest.dart` 新增 5 条（引号、盘符根、/MIR、stage 清理、
  进程边界；共 27 项）。

### 验证（实测）
- `flutter analyze`：No issues found
- 客户端 5 套：43 + 63 + 11 + 39 + 27 = **183 通过 / 0 失败**
- 服务端 4 套：70 + 19 + 35 + 41 = **165 通过 / 0 失败**
- Windows：解压 hlh.19 新包后启动，`exited=False`，stderr 无
  `MissingPluginException`，`%APPDATA%\io.github.dey410\gardendless_loader` 已创建
- 更新通道：APK / Windows 清单均返回 200，`latest=90019`，size/sha 与磁盘一致，
  zip 下载 200
- Release：`v0.9.0-hlh.19` 两个资产 `uploaded`

### 产物
- APK 58,634,580 B `30a6ac27a29656c7bdf2810572c3fc8fcd87b3a0b45dc6f6fc2c65f950de0b6e`
- Windows zip 190,010,310 B `ec606fdf58767e8aecff18e19f9da27a82d40f2e76036ed593004029356e33fb`

### 遗留
- B-18（新增）：管理页只显示 legacy 存档，按版本分区的存档不可见。
- 安卓真机验收与 Windows 首次自动更新仍需用户点击。

## R-20261025-01（hlh.20 存档页）/ orchestrator(opencode) / 2026-10-25T15:45+08:00

- status: review
- 版本: `0.9.0-hlh.19+90019` → `0.9.0-hlh.20+90020`
- 触发：安卓实机反馈——下载新资源包后存档页 0 条、冲突提示没有入口、
  游戏内「上传」按钮点不动、21:9 面板拥挤

### 现象 → 根因 → 改法 → 断言

#### 存档页 0 条（P0）
- **现象**：云端截图显示 `akadmin`、0 条目；游戏内却提示存档冲突。
- **根因**：客户端按资源包版本请求 `/load?gameVersion=0.16.1`，而该账号的 4 份
  存档都在**未分区**（legacy）目录。`pick_load_version` 只把 `by-version/*`
  当作可继承来源，legacy 被排除 → 返回 `kind=none`、`data={}`；游戏页的
  `gameVersion` 为空，仍在往 legacy 写，两边永远对不上。
- **改法**：legacy 作为「最旧来源」参与继承，命中时返回 `load_kind=migrated`。
- **断言**：test-save-versions.sh 第 9 节 6 条（migrated、内容、adoptable、冲突标记）。

#### 普通用户看不到历史/回滚（P0）
- **现象**：页面只有 0 条；即便有数据，历史按钮也因 `snapshot.isAdmin` 被隐藏。
- **根因**：`/history`、`/version`、`/raw` 一律要求管理员；管理页对非管理员直接
  显示「需要 Admins 组」。游戏内 FAB 也只在 `d.is_admin` 时挂载。
- **改法**：三接口允许本人（跨用户仍需管理员）；`/list` 非管理员只返回本人，
  并新增 `saves[]`（legacy + 各版本）；管理页按 `gameVersion` 操作；FAB 全员挂载。
- **断言**：test-cloud-saves.sh 7.9 节 3 条 + 8.5 节 5 条。

#### 游戏内「上传」按钮点不动（P1）
- **现象**：右下角只有「↑ 上传」，普通账号没有管理面板；按钮与面板职责混乱。
- **改法**：移除独立上传按钮；自动上传只由 `sync.js` 在游戏运行时执行；
  右下角统一为「存档」按钮，打开与 Web 端一致的 `app-admin.html`。
  冲突提示条新增「打开存档面板」按钮，不再只给文字。
- **断言**：`app-ui.js` 静态断言（全员挂载、无独立上传、冲突入口）。

#### 分区参数一致性（P1）
- **改法**：`CloudSaveSnapshot` 记录服务端实际分区；历史/回滚沿用该值，
  不再用请求版本（否则显示 legacy 数据、历史却查 by-version 空目录）。
- **断言**：`check_game_host_contract.dart` +4 条（legacy/版本号解析、参数、去管理员门禁）。

#### 21:9 短屏（P2）
- 面板在 `max-height:430px` 时贴满、压缩标题栏；游戏画面比例仍由
  「画面比例」设置（均衡/完整/拉伸）控制。

### 验证（实测）
- `flutter analyze`：No issues found
- 客户端 5 套：43 + 63 + 11 + 43 + 27 = **187 通过 / 0 失败**
- 服务端 4 套：78 + 19 + 35 + 41 = **173 通过 / 0 失败**
- `/load?gameVersion=0.16.1`（akadmin）：`kind=migrated`，返回 4 个键
- `/list` 非管理员：只返回本人 4 份 legacy 存档
- Windows 启动：`exited=False`，无 `MissingPluginException`
- 更新通道：APK/Windows 清单 200，latest=90020，size/sha 与磁盘一致

### 产物
- APK 58,634,593 B `ef56cc34070b681e8e2fa9312fbdb72b9deb8d93faeecffa0bdc01f3b2d967b3`
- Windows zip 190,010,037 B `bc3064ab0b093d1f05698d8be560a37f73033d3b71111ee6bc5ec1bea383669b`

### 遗留
- 21:9 游戏画面若仍被裁切，需确认「画面比例」设置（默认均衡 = 17:9 视口）。
- 真机复测：进游戏确认右下角为「存档」，面板能列出版本/历史并回滚。

## R-20261025-01（hlh.21/22 21:9 与桌面宿主）/ orchestrator(opencode) / 2026-10-25T16:35+08:00

- status: review
- 版本: `0.9.0-hlh.20+90020` → `0.9.0-hlh.21+90021` → `0.9.0-hlh.22+90022`
  （.21 发布后发现 Windows 主界面仍有一个桌面宿主异常，.22 一并修复并替代）

### 现象 → 根因 → 改法 → 断言

#### 21:9 画面被裁切 / 强制 16:9（P0）
- **根因**：`GameViewportSize.fit` 对 `BALANCED` 把视口夹在 16:10–17:9，
  21:9 手机拿不到真实比例。
- **改法**：`BALANCED` 直接返回窗口宽高（原生比例）；`SHOW_ALL` 保留 17:9、
  `STRETCH` 保留原行为。设置项文案改为「跟随屏幕」。
- **断言**：`GameViewportSizeTest` 4 项（4:3 / 16:9 / 20:9 / 21:9 原样返回）。

#### Windows「游戏」页抛 Unsupported operation（P0）
- **根因**：`GameHostPlatform.current()` 只枚举 android/ios/ohos；Windows 的
  `_Hero` 构建时调用 `nativeHostName`，直接抛 `UnsupportedError`。
- **改法**：枚举增加 `desktop`（`dart-desktop`，本地 HTTP + webview_cef），
  windows/linux/macos 映射到它；原生活会话路径不变。
- **断言**：`check_game_host_contract.dart` +4 条（Windows/Android 映射、
  展示名、未知平台报错）；Windows 实机启动 stderr 不再出现该异常。

#### 21:9 启动器/面板布局（P1，@designer）
- 侧边栏短屏收窄 + 滚动；开始页短屏整体滚动；存档页双栏（窄屏单列）；
  游戏内面板 ≤540px 全屏、触控目标 ≥40px。
- 验证：`flutter analyze` 干净；5 套 191 项全绿；`node --check ui.js`。

### 验证（实测）
- 客户端 191 项、服务端 173 项，合计 **364 通过 / 0 失败**
- Windows 启动：`exited=False`，无 `Unsupported operation`，无未捕获异常
- 更新通道：APK/Windows 清单 200，latest=90022，size/sha 与磁盘一致
- Release：`v0.9.0-hlh.22` 两个资产 uploaded

### 产物
- APK 58,634,588 B `d7e36a690a6712bbccb728ec7a1f6ad35f1207bd7499f9de8cd16ee737fb857b`
- Windows zip 190,021,461 B `20a90b2cd541ebe0c76fbc9f6bf2fbe3aa2832274756d10b8309b1e22f20a220`

### 遗留
- 真机复核：21:9 进游戏确认铺满且不裁切；存档页滚到底部；面板可操作。

## R-20261025-02（存档面板 Web/Windows/Android 修复）/ orchestrator(opencode) / 2026-10-25T17:25+08:00

- status: review
- 版本: `0.9.0-hlh.22+90022` → `0.9.0-hlh.23+90023`（构建中）

### 现象 → 根因 → 改法 → 断言

#### Web 存档管理不可用 / 只提示差异，不能下载（P0）
- **根因 1（静态漂移）**：nginx 直接 alias `/var/www/pvzge-save`，源码改了但
  `ui.js/admin.html/conflict.html` 仍是 13:14 的旧副本。旧 `ui.js` 只给管理员
  挂 FAB，普通用户只有「↑ 上传」；旧 `admin.html` 没有版本维度/下载。
- **根因 2（版本丢失）**：nginx 先同步执行 `sync.js`，后 defer 执行
  `version-check.js`，`GAME_VERSION` 恒为空 → Web 所有 `/load`、`/save` 不带
  `gameVersion`，进度全写进 legacy；冲突页又用无版本 `/load`，看不到当前版本云端。
- **改法**：`sync.js` 从页面标题兜底版本并回填 sessionStorage；冲突页按
  `gameVersion` 读写，新增「下载云端存档（JSON）」，空云端禁用并说明；管理页
  手动上传取当前版本并带 `gameVersion/baseVer`；新增 `tools/deploy-static.sh`
  统一生成/部署/核对；删除独立「↑ 上传」按钮，入口收口到「存档」面板。
- **断言**：cloud 套件 +19（面板/部署/触控/绝对地址）；sync 套件 +3
  （标题版本、sessionStorage、冲突跳转带版本）；真实 Chrome 冲突页下载/
  覆盖/上传与 Web 面板普通用户上传均通过。

#### Android 游戏内面板按钮全死 / 面板空白（P0）
- **根因 1（触控）**：原生 `touch_input_adapter.js` 在 document 捕获阶段对
  所有 touchstart `preventDefault`，注入 DOM 收不到 click；只有用 pointerup
  的 FAB 能点，顶部提示条/关闭/面板按钮全失效。
- **根因 2（空白 iframe）**：`app-ui.js` 生成器用相对路径
  `/_save/app-admin.html`；离线包 origin 是 `appassets.androidplatform.net`、
  桌面端是 `127.0.0.1`，相对路径落到本地资源服务器 404，面板只剩 `#12151c`。
- **改法**：原生适配器把 `data-pvz-ui`/固定 id 当原生控件放行；`ui.js` 在
  window 捕获阶段保护自身（旧 APK 也生效）；生成器用 `cfg.base` 拼绝对地址。
- **断言**：`check_touch_patch.mjs` +2 组（属性/旧 id 放行）；Chrome 模拟
  document 捕获消费：旧 UI 冲突条按钮 0 次打开、关闭后 mask 仍在；新 UI
  全部 1 次打开、iframe 内按钮可点；真实 app-admin 以 zz-panel 加载。

### 验证（实测）
- 服务端 **201 通过 / 0 失败**：cloud 97、concurrency 19、versions 41、sync 44。
- 客户端 **191 通过 / 0 失败**；`flutter analyze` 干净；Android JVM 视口 4 项。
- `test-cloud-saves.sh` 连续 3 次 97/0；修复 `printf|grep -q` 在 pipefail 下
  的 SIGPIPE 假失败（200 次实测 186 次误报）。
- `bash tools/deploy-static.sh --check` 9 个文件全部一致。

### 产物
- APK 58,634,998 B `8e6858b62c9c2e4fd5c7a17de4b47b5185139204c6d6d76c7276605309151d17`
- Windows zip 190,024,520 B `66a106484b036eb7ea846f1183a14766672104fd0fe8802f36b133885a302f25`
- Release `v0.9.0-hlh.23` 两个资产 uploaded；服务端 `26540fc` 已推送。

### 遗留
- 真机复核：Android 21:9 进游戏后点顶部提示条/面板关闭/下载；Windows 首次
  自动更新后打开「存档」面板确认 iframe 有内容。
- Web 首次按版本加载会把 legacy 迁移到 0.16.1；若本机比云端新会进冲突页，
  这是预期行为，先下载云端 JSON 再决定。

## R-20261025-03（存档冲突直接可操作 + App 面板下载桥）/ orchestrator(opencode) / 2026-10-25T17:55+08:00

- status: review
- 版本: `0.9.0-hlh.23+90023` → `0.9.0-hlh.24+90024`

### 现象 → 根因 → 改法 → 断言

#### 冲突提示只给入口，不能直接处理（P0）
- **现象**：游戏内冲突只显示「本次以本机为准」横幅，用户要自己点进存档面板找
  下载/覆盖，实际就是「看着冲突没法动」。
- **根因**：冲突状态只挂 `window.__pvzConflictNotice` 并渲染一条横幅，没有把
  `/load` 的云端内容与可执行动作接到提示上。
- **改法**：`ui.js` 新冲突面板（本机/云端摘要、版本/设备/时间、下载云端 JSON、
  保留本机并上传、启动阶段覆盖本机、稍后处理/重开横幅）；`sync.js` 给提示加
  `phase: startup|runtime`；运行中隐藏覆盖按钮，启动阶段才允许覆盖并 reload。
  「保留本机」走 `__pvzSave.keepLocal()`，成功后发 `pvz-save-conflict-resolved`
  关面板，失败发 `failed` 并显示服务端原因。
- **断言**：cloud 套件 +5（面板动作/导出桥/静态一致）；sync 套件 +12（phase、
  keepLocal 的 force/gameVersion、零接受）；Chromium 探针自动打开、摘要、
  下载、保留、运行中隐藏覆盖全部通过。

#### 保留本机上传 200 但零接受仍报成功（P1，本轮新发现）
- **根因**：`forceUploadLocal` 只判断 `x.status === 200`，未看服务端 `saved`。
  单键超限/空档保护时服务端返回 200 + `saved: []`，客户端却清 pending、推进
  meta、发 resolved，改动会静默丢失且不再重试。
- **改法**：按 `saved` 计算真正被接受的键，只对它们推进 meta/清 pending；
  零接受发 `failed` 并保留冲突提示；部分接受保留其余改动，下次同步重试。
  老服务端不返回 `saved` 时按全部接受处理，保持兼容。
- **断言**：`tools/test-sync-offline.js` [15] 5 条（不发 resolved、failed 带原因、
  保留提示、meta 不前进、本机改动仍在）。

#### App 面板单条下载在 Android 无反应（P1）
- **根因**：面板是跨源 iframe，`<a download>` 只在游戏页被
  `export_download_patch.js` 接管；Android WebView 没有 DownloadListener。
- **改法**：app-admin.html 检测 `__PVZGE_APP__` + 跨源父窗口，改为
  `postMessage({type:'pvz-export', name, text})`；游戏页校验 `e.origin` 等于
  配置的服务器 origin 后再走同一个 Blob/导出补丁。
- **断言**：cloud 套件「App 管理页下载走游戏页导出桥」；Chromium iframe 探针
  收到 `pvz-export` 且内容与存档一致。

#### 冲突面板按钮可能被原生触控层吞掉（回归防守）
- **改法**：原生 `touch_input_adapter.js` 把 `pvz-conflict-modal` 加进旧脚本
  id 兜底放行列表；面板本身带 `data-pvz-ui`。
- **断言**：`tool/check_touch_patch.mjs` 通过；Chromium 模拟 document 捕获消费
  时启动/运行两种冲突面板按钮均一次点中。

### 验证（实测）
- 服务端 **231 通过 / 0 失败**：cloud 102、concurrency 19、versions 54、sync 56。
- 客户端 **191 通过 / 0 失败**；`flutter analyze` 干净；Android JVM 视口 4 项。
- `bash tools/deploy-static.sh --check`：9 个文件全部一致。
- Chromium 探针：Web 冲突面板、App 启动/运行冲突面板、app-admin 下载桥全部通过。

### 产物
- APK 58,635,013 B `cdf5a52ccd9ea09c70a2c1c36643648f80c9288d85c69943e203438050d7f248`（v1+v2+v3）
- Windows zip 190,024,526 B `7b6990761e56ee4d8c04a2c91d1cde3eabe46d7cfb89811718da1c739d3f15b0`
- Release `v0.9.0-hlh.24` 两个资产已上传；服务端 `95defc2` 已推送。

### 遗留
- 真机复核：冲突面板下载/保留/关闭/重开一次点中；「保留本机并上传」后云端历史
  有旧版；App 面板单条下载落到系统导出目录。
- Windows 首次原地更新后复核面板与下载导出。

## R-20261025-04 / orchestrator(opencode) / 2026-10-25T21:40+08:00

### 背景
hlh.24 已发布。本轮修正存档版本与归属语义，并实现一个账号多份玩家数据。
**未发版、未部署、未提交**；服务端改动等 Hermes 部署后再做公网 E2E。

#### 云端整包数组导致改 A 推进 B（P0，本轮需求）
- **现象**：一个账号只能有一份 `PvZ2_PlayerProperties` 文件；两台设备分别改
  不同玩家时，后写者会把对方的玩家回退；单玩家历史/回滚也无法独立。
- **根因**：云端把游戏数组当不可分割文件，revision/历史/冲突都按整个键算。
- **改法**：服务端拆成 `profiles/<uuid>.json` + 原子 `profiles.json`；游戏仍收发
  数组，`/load` 注入 `__pvz_profile_id`；`/save` 按 `changedProfileIds` /
  `baseProfileVer` 逐玩家合并，删除只认显式 `deletedProfileIds`；新增
  `/profile/history`、`/profile/restore`。客户端 sync.js 记录每份玩家的
  revision + 内容指纹，只上传真正变化的玩家。
- **断言**：`test-save-versions.sh` 第 11 节 25 条；`test-sync-offline.js`
  第 17-18 节 9 条；`test-concurrency.py` 12 客户端只有一个写入成功。

#### 同名用户可认领别人的存档（P0）
- **现象**：路径与权限都按 username，authentik username 可改名/重名。
- **根因**：缺失 uid 维度的所有权校验。
- **改法**：nginx 转发 `X-Authentik-Uid`；`identity.json` 绑定 username 目录，
  同名不同 uid 403；令牌记录 uid，`REQUIRE_UID=1` 时旧令牌要求重新登录；
  `/list` 与管理页展示 uid 短标识。
- **断言**：`test-save-versions.sh` 第 11 节「同用户名不同 uid 被拒绝 / 同一 uid 重复通过」。

#### 存档页版本来源混用（P0）
- **现象**：旧 B-19 在在线形态先补远端版本，但本地查看也可能拿到线上版本；
  本地无资源时退化为 legacy 查询。
- **根因**：存档页只有一个 `_playGameVersion()`，没有「查看分区」概念。
- **改法**：`cloudSavesViewOnline` 默认跟随 playMode，可手动切换；本地查看用
  `currentGameVersion`，在线查看用服务器清单版本；缺资源/缺在线版本分别返回
  `local_resource_missing` / `online_version_unavailable`，不再退 legacy；
  切换只影响查看，运行中会话版本在启动时固定。
- **断言**：`tool/check_game_host_contract.dart` 5 条（分区取版本、两种失败码、
  本地用资源版本、generation 作废在途响应）。

#### 桌面端随机端口导致串档/丢失（P1）
- **根因**：`HttpServer.bind(..., 0)` 每次启动随机端口；localStorage 按 origin
  （含端口）隔离。
- **改法**：本地/在线各自首次分配并持久化固定端口；端口占用抛
  `LocalPortUnavailableException`，启动器明确失败，不静默换 origin。CEF 磁盘
  缓存仍需原生补丁（B-22，Windows 实机验证）。
- **断言**：`check_local_server.dart` 9 条；`check_game_host_contract.dart` 3 条。

#### 降级时高版本 localStorage 会被旧游戏读（P0）
- **现象**：换资源版本不换 origin（Android 本地固定 appassets、桌面本地端口固定），
  旧版本游戏会直接读到新版本写下的存档，改写 `version` 后可能被同步回云端。
- **根因**：版本隔离只在云端做，本机没有「上次写入的版本」上下文。
- **改法**：游戏脚本执行前注入 `local_save_guard`：读 `__pvzSaveContext`，
  本机版本高于当前资源版本时把四个游戏键备份到 `__pvzBlocked_<旧版本>_<键>`
  并移出活动键；升级只记录上下文。Android 在 `GameActivity.appendLocalSaveGuard()`，
  桌面在 `_prepareDesktopGameInternal` 与存档桥一起注入（未登录也生效）。
- **断言**：`check_game_host_contract.dart` 5 条（上下文键、备份+移除、空版本跳过、
  Android 顺序、桌面注入）。

#### 普通用户不能回滚自己的存档（P1）
- **根因**：`/restore` 前有全局 `if not admin` 门禁，后面的本人判断永远走不到。
- **改法**：移除全局门禁，由各 handler 用 `can_manage()` 校验目标；`/profile/restore`
  同样本人可用。
- **断言**：`test-save-versions.sh` 第 11 节权限 3 条。

### 验证（实测）
- 服务端 **180 通过 / 0 失败**：save-versions 90、concurrency 19、sync-offline 71
  （cloud-saves 102 需部署后重跑，未计入本轮实测）。
- 客户端 **208 通过 / 0 失败**：local-server 52、storage-migration 63、
  desktop-zip 11、game-host-contract 55、update-manifest 27。
- `flutter analyze`：`No issues found!`
- `app-sync.js` 由最新 `sync.js` 生成并通过 node --check；与生成物逐字节一致。

### 遗留
- Hermes 部署：重启 save-api、`deploy-static.sh --check`、nginx uid 转发；
  详见 `/home/hlh/pvzge/docs/app-cloud-saves.md` 第 10 节。
- 公网 E2E：真实账号本地/在线版本不同、legacy 继承、多玩家合并/单玩家回滚。
- 真实用户 uid 目录迁移（B-23）、Windows CEF 磁盘缓存（B-22）。

## R-20261025-04 / orchestrator(opencode) / 2026-10-25T22:19+08:00（review 打回后修复）

- status: review
- readBack: { taskTitle: "多玩家云存档 + 存档页版本来源修正 + 桌面固定 origin", versionBefore: "0.9.0-hlh.24 (90024)", testsBaseline: "490 项（服务端 282 + 客户端 208）" }
- 触发：`oracle-sol` 完整 review 判定「阻塞部署」，指出静默丢改动、误删玩家、跨用户提权三类 P0。
- 修复：
  1. **新玩家 ID 回填**：服务端分配 `profileId` 后 sync 回填本机数组与 pending；无 ID 的连续编辑不再被 `changedProfileIds` 过滤丢弃。
  2. **tombstone**：已删除 ID 被旧设备带回 → `profileConflicts`，不复活、不换新 ID；恢复只走 `/profile/restore`。
  3. **CAS 收紧**：现代协议已存在玩家缺 `baseProfileVer` 直接冲突；`force` 不再隐式删除未见玩家，整包回滚改用 `replace_missing`。
  4. **sync 基准**：只推进本机真正持有内容的 revision；未见过的云端玩家不进删除集；冲突/未接受不推进基准；延迟 ACK 比较队列值。
  5. **管理页 XSS**：玩家 coin/gem 统一 `esc()`；回滚携带历史文件名，避免同秒恢复错版本。
  6. **UID 所有权**：已绑定目录默认拒绝无 uid；首次绑定加文件锁；`IDENTITY_CLAIM=strict` 阻止旧目录被同名请求认领；过渡开关 `ALLOW_LEGACY_NOUID` 默认关闭。
  7. **本机版本保护**：按版本归档/恢复游戏键与同步状态；降级后推进 context；连续启动同版本不覆盖备份；升级恢复目标版本自己的存档。Android 改为读取 Dart 生成的 `__local_save_guard.js`，不再维护两份逻辑。
  8. **换账号隔离**：按 uid 归档上一账号的本地存档与 pending；`/load` 失败时不上传；迁移只回写 migrated 键且不覆盖本地 pending。
  9. **单玩家回滚**：只替换该玩家，B 的 pending 保留；重放只带 B。
  10. **其余**：历史/回滚逐键来源；请求 generation+token+user+view+version 校验；本地形态也能取在线清单；旧服务端无 profiles 时展示全部 entries；端口首次持久化失败停掉已绑定 server；删除玩家键同时清 manifest；破坏性接口非法版本 400；删除/回滚前留最新历史快照。
- 实测：save-versions 114/0、concurrency 28/0、sync-offline 107/0（Web 与 App 各一遍）、sync-live 8/0、local-server 52/0、storage-migration 63/0、desktop-zip 11/0、game-host-contract 73/0、update-manifest 27/0、cloud-saves 离线 9/0、local-save-guard 15/0；`flutter analyze` 无告警；Android compile + viewport 单测通过。
- 新基线：**609 项（服务端 359 + 客户端 250）**；`cloud-saves` 102 仍待部署后复跑（新增 2 条静态转义断言，预计 104）。
- 未做：B-26 多玩家提交崩溃一致性、B-27 桌面端口重置入口、B-28 整包回滚跨事务边界；服务端未部署、APK/Windows 未重建、未提交。

## R-20261025-04 / orchestrator(opencode) / 2026-10-25T22:43+08:00（冲突应用 + CEF 日志上限）

- status: in_progress
- 触发：用户报告 Web 冲突面板选「下载最新云端」只下载 JSON、没有应用到 localStorage；另外实机 CEF `debug.log` 涨到 250 GB。
- 修复：
  1. **冲突面板应用云端**：面板本来就只在运行时出现，「用云端覆盖本机」却被 `phase === 'runtime'` 隐藏，只剩下载 JSON。现在改为「用云端存档（覆盖本机并重启）」，下载降级为「下载备份（JSON）」。
  2. **启动前应用快照**：面板/冲突页不再直接写游戏键（游戏内存里的进度会在卸载时盖回去），改为写 `__pvzAdoptCloud`；`sync.js` 启动时在 `/load`、冲突判定和游戏读档之前应用：写键、对齐 meta、丢弃这些键的 pending、玩家基准用快照的 `profileVer`。快照带版本 + 30 分钟 TTL，标记期间禁止上传。
  3. **CEF 日志上限**：`windows/runner/cef_log_limit.cc` 每 15 秒检查 exe 目录与工作目录的 `debug.log`，超过 32 MB 清空；实机验证 CEF 共享写句柄可在运行中裁剪。
  4. **移动端日志配额**：Android/OHOS/iOS 原来只在进程启动时清理一次，换段时补一次总量清理，并跳过正在写的段——长时间运行不会突破 10 MB 配额。
- 实测：sync-offline 120/0（Web 与 App 各一遍）、update-manifest 32/0、game-host-contract 76/0、`flutter analyze` 无告警；MSVC `/W4 /WX` 编译 `cef_log_limit.cc` 通过；Windows 实机裁剪探针 `truncate=ok`、文件从 0 重新增长；Android `compileDebugKotlin` + `GameViewportSizeTest` 通过。
- 新基线：**630 项（服务端 372 + 客户端 258）**。
- 未做：Windows 包未重建（上限未进产物）、服务端/静态文件未部署、本轮新代码等 oracle-sol 额度恢复（2026-10-26 01:13）后复核。

## R-20261025-04 / orchestrator(opencode) / 2026-10-25T22:52+08:00（部署）

- 用户要求先部署并重新生成产物（原计划交 Hermes）。
- 备份：`backups/20261025-pre-deploy-saves.tgz`（15 MB 源数据）、`...-static.tgz`、`...-nginx.conf`；源数据 476 个文件 sha256 清单，部署后 `sha256sum -c` rc=0。
- 静态：`tools/deploy-static.sh` 部署 6 个源文件 + 重新生成 `app-sync.js`/`app-ui.js`/`app-admin.html`；`--check` 全 ok，无 DRIFT。
- 服务端：`docker restart pvzge-save`（挂载 `/home/hlh/pvzge/save-api`），`/healthz` ok；探针 `/load` 已返回 `profiles`/`profileVer`/`keySources`/`restoredProfiles`，探针用户已删除。
- 验收：`tools/test-cloud-saves.sh` **108 通过 / 0 失败 / 0 跳过**（经本机 nginx `--resolve`，含新增冲突面板快照断言）。
- 未做：nginx `X-Authentik-Uid` 转发（本机无 root，`nginx -t` 还受证书权限限制）→ 交 Hermes；完成前 `akadmin` 不绑定 `identity.json`，旧 App 令牌仍可用。
- 新基线：**636 项（服务端 378 + 客户端 258）**。
- 追加（22:55）：得到 root 授权后完成 nginx 部署——`/_save/api/load` 与 `/_save/api/` 增加
  `auth_request_set $save_uid` + `proxy_set_header X-Authentik-Uid $save_uid`，`nginx -t` 通过并
  reload；Bearer 通道仍显式清空 uid。配置备份 `nbpc-gateway.conf.bak-20261025-225534`。
- 影响：`akadmin` 下次登录会绑定 `identity.json`；现有 13 个令牌均无 uid，旧 App 设备令牌届时
  401，需要在 App 重新登录（必要时临时 `ALLOW_LEGACY_NOUID=1` 过渡）。

## R-20261025-04 / orchestrator(opencode) / 2026-10-26T00:45+08:00（Web + Android E2E，自动上传修复）

- 触发：用户反馈「手动上传没问题，自动上传似乎不及时，最新的应该是手动上传的版本」。
- 根因 1（手动上传基准）：管理页上传成功只改云端 revision，没有推进同源游戏标签页的
  `__pvzCloudProfiles`；游戏下一次自动上传仍带旧基准 → `PROFILE CONFLICT`。修复：
  上传成功后合并响应 `profileVer`/`ver` 到同源 localStorage；跨源 App iframe 保持不动。
  服务端同时返回 `profileUnchangedIds`，内容未变时客户端也能推进基准。
- 根因 2（纳秒版本号）：非玩家键 `baseVer` 是 1.7e18 纳秒，浏览器 double 回传会舍入
  （...477579 → ...477600），服务端精确整数比较永远 `stale_base`。修复：
  `same_save_version()` 按 double 相等判断同一版本；真实写入仍冲突。
- 实测（部署后）：`test-save-versions.sh` **126/0**、`test-concurrency.py` **28/0**、
  `test-cloud-saves.sh` **108/0/0**、`test-sync-live.js` **9/0**、
  `test-sync-offline.js` **139/0**（Web+App）、`test-admin-baseline.js` **16/0**；
  `flutter analyze` 无告警；client 五套 52/63/76/32/15 + desktop-zip 11 + cloud-saves 离线 9 全绿；
  Android `:app:testDebugUnitTest` 全绿（新增 OnlineGameResourceClientTest 3 项）。
- Web E2E（临时 authentik 用户 `zz-e2e-20261025`，uid f202ce7b…，测试后清理）：
  账号切换隔离（akadmin 本地 pending 未上传到测试账号）；T1/T2 两个玩家 ID 回填
  dd00da60…/c5d6ec0e…；手动上传后自动上传 777/666 无冲突；运行时冲突面板本机 888 /
  云端 999，「用云端存档」重启后本机 999、pending 清空；启动冲突页「使用云端」→ 999、
  「保留此设备」→ 云端 2222；管理页基线推进到 a99bf372/61223ce4。
- Android E2E（`pvzge_api35`，debug APK 用 `--dart-define=PVZGE_SERVER=<server>`
  重建）：原生 LoginActivity 登录成功；Saves 页显示账号、Account ID f202ce7b、两名玩家
  T1 2222/5（ID dd00da60…）、T2 666/7（ID c5d6ec0e…）；本地/在线版本切换正常
  （本地无资源包提示）；T1 历史 9 版，回滚到 999 成功（新 rev ce3e9083，2222 保留在历史）。
- 发现并修复 B-32：Kotlin `readBridgeCredentials` 只认双引号，而 Dart 生成单引号桥，
  在线资源代理判成 `online_bridge_missing` → 游戏 WebView 401。正则改为单/双引号，
  新增 JVM 单测 3 项；`app/build.gradle` 加 test 用 org.json。
- 自审发现并修复 B-36（多设备静默丢档）：`save_players` 对「不在 changedProfileIds、
  但内容与云端不同」的旧副本走 changed=False 并保留云端；`profileUnchangedIds`
  又把它登记成已同步，客户端把基准推进到云端 revision + 本机旧内容 hash，下一次编辑
  会带云端 revision 静默覆盖另一台设备的进度。修复：只有逐字节一致才回报 unchanged。
  新增 5 条回归（121→126），生产实例 126/0；`test-sync-live.js` 加 1 条真实 sync.js 集成（8→9）；顺带修第 12 节测试隔离
  （`/save` 用 zz-mp2-test、`/delete` 却删 zz-newmp-test，二次运行必挂）。
- 另修管理页基准推进的版本边界：PAGE_GV 为空（管理页没识别到分区）时，
  响应里的 legacy revision 不能混进游戏标签页的 0.16.1 基准；现在要求
  PAGE_GV 明确且等于 base.gv 才推进。test-admin-baseline 11→13。
- 未完成：修完桥后在线游戏在模拟器首屏 WebView 渲染进程 crashpad 崩溃 + ANR，
  需真机/硬件 GPU 复测（B-33）；Windows 包仍未重建；iOS/OHOS 日志改动未在本机构建。
- 新基线：**684 项（服务端 426 + 客户端 258）**；等待 01:13 后交 oracle-sol 复核。

## 2026-10-26 02:06 — oracle-sol 第三轮 P0/P1 修复

第三轮复核在上一轮修复后仍复现 8 条：force 绕过单飞（3→2）、migrated 覆盖启动
冲突、换号丢目标 pending、单玩家回滚后旧 pending 复活、generation 未覆盖普通恢复/
flush 竞态/applyCloudSave、pump 不排空持久队列、删除 ACK 的 unchanged/新玩家遗漏、
管理页老服务端 fallback 把「发过」当「确认」。

修复落在 `save-api/sync.js` 与 `save-api/admin.html`：force 与普通上传共用 inflight
通道并在 onloadend 汇合；迁移只回写 `loadConfirmed`；换号/回滚后重读 pending；
所有接管入口推进 `__pvzSyncGeneration`，同步流程写统一走 `guardedWrite`（写前检查 +
写后复检回滚）；pump 在内存空时 drain 持久队列；删除 ACK 接受判定统一；admin
要求 `saved` 明确包含玩家键。

`test-sync-offline.js` 139→163（Web/App 各一遍）、`test-admin-baseline.js` 16→19；
save-versions 126/0、sync-live 9/0、cloud 108/0/0、concurrency 28/0；服务端 453、
总 711。静态已部署（sync.js `75274718…`、admin.html `a53ac376…`、
app-sync.js `0461caf6…`），deploy-static --check 9 项全 ok。生产 `akadmin`
18:03–18:04 连续 200 /save，无 BLOCKED/CONFLICT。残余 B-38（同时正常游玩仍无
活跃写者租约）按 P2 记录。已重新提交同一 oracle-sol 会话复核。

## 2026-10-26 03:15 — oracle-sol 前手工复核第五轮

在等 oracle-sol 额度（06:16 重置）期间逐段复核 `sync.js` / `server.py` / `admin.html`，
又找到并修掉以下问题（先补断言再修，新增 sync-offline 28 条、save-versions 11 条）：

1. **运行期换号**：`/save` 增加 `expectedUid`，服务端在当前会话 uid 不一致时 403
   `identity changed` 且不写入；客户端保队列、停止后续上传并发
   `pvz-save-identity-changed`。管理页手动上传先比对 `__pvzSyncUser` 并携带
   `expectedUid`，避免把 A 的本机档写进 B。
2. **force 200 不可解析**：旧代码把 HTTP 200 的 HTML/代理错误当「全部接受」清队列；
   现在与普通 send 同一判据，保留 pending 并发失败事件。
3. **版本不匹配首传**：云端只有更高版本时，firstUpload 不再把本机碰巧存在的旧档
   塞进 pending（否则升级后被当成未上传改动重放）。
4. **整包回滚身份**：兼容镜像保留 `__pvz_profile_id`；`/restore` 显式 `allow_restore`，
   旧快照无 ID 时按位置/唯一名字从 tombstone 找回原 ID；管理员代回滚时
   ownerUid/ownerUsername 仍归属目标目录。
5. **单玩家回滚回插**：本机已删除的玩家被管理员从历史恢复后，重新插回 local 与
   pending 并更新基准，避免下一次上传再次 `deletedProfileIds` 删掉回滚。
6. **删除重置回滚标记**：删除玩家键时清 `.meta` 的 `restoredAt/restoreSource`，
   新档不会被旧回滚标记误伤。
7. **原生写入 fencing**：回填 profileId、单玩家回滚、运行时「用云端」统一走
   `guardedRawWrite`（写前检查 + 写后复检回滚）；adopt 接管竞争失败保留 marker。

实测：sync-offline **225/0**（Web 与 App 各一遍）、admin **19/0**、save-versions
**137/0**、sync-live **9/0**、concurrency **28/0**、cloud-saves **108/0/0**；静态
`deploy-static.sh --check` 9 项全 ok。服务端 **526** + 客户端 **258** = **784**。
`analyze` 与客户端 258 项本轮未改 Dart/Kotlin，未重跑，沿用上一轮全绿证据。

未做：本轮 `server.py` 改动尚未重启 `pvzge-save` 加载（生产仍在跑上一版，
expectedUid 等保护未生效）；静态 `sync.js`/`admin.html` 已部署。oracle-sol
额度 06:16 重置后复核；复核通过前不关闭任务，也不清理临时 E2E 账号
`zz-e2e-20261025`。

## 2026-10-26 04:10 — oracle-sol 前手工复核第六轮

在等额度重置期间继续逐段复核 `sync.js` / `server.py` / `conflict.html` / `ui.js`，
又找到并修掉 6 类问题（先补断言再修，新增 sync-offline 18 条、save-versions 5 条、
cloud-saves 3 条静态断言）：

1. **换号归档写失败会丢本机存档**：`switchUser` 先写归档再无条件清本机键，配额满/
   隐私模式下 setItem 静默失败 → 唯一存档被删。改为逐键归档读回校验，失败中止
   换号、保留旧账号存档、本页放弃云同步并提示刷新；恢复目标账号归档同样只有
   落地成功才删归档。
2. **generation 写失败无限 reload**：`takeOverDocument` 写 `__pvzSyncGeneration`
   失败仍推进内存 generation，`writerStale()` 恒真 → 恢复/基准发布反复 reload。
   改为写后读回校验，失败不推进、降级为旧行为继续启动。
3. **profileId 回填张冠李戴**：`resp.profiles` 里「云端有、本次没发」的玩家按
   提交后 index 返回，可能与请求在途期间新建的同名玩家位置重合，导致下一次保存
   覆盖那份云端进度。只回填本次发送数组内同位置、内容哈希未变的条目。
4. **跨版本 pending 覆盖新版本**：升级后旧版本离线改动会被当成「本机更新」传进
   新版本 exact 分区。启动时若上次同步版本不同且云端当前版本已有该键，丢弃该键
   的旧 pending（转正常冲突/恢复）；只有 migrated/none 才允许升级搬运。
5. **冲突页跨账号写入**：冲突页「保留此设备」是独立页面直接 `/save`；改为上传前
   重新 `/load` 复核账号、用最新 `ver` 做基准、带 `expectedUid`、响应身份不一致
   即停止；摘要字段加转义。
6. **设备元数据覆盖回滚标记**：玩家键的 `record_device` 在 profile 锁外做整文件
   读改写，会和 `/profile/restore`、`/restore` 的 `restoredAt` 交错。移入
   `save_players` 的 profile 锁内，且只记真正写入玩家文档的请求。

实测：sync-offline **243/0**（Web 与 App 各一遍）、admin **19/0**、save-versions
**142/0**、sync-live **9/0**、concurrency **28/0**、cloud-saves **111/0/0**；静态
`deploy-static.sh --check` 9 项全 ok（2026-10-26 04:03）。服务端 **552** + 客户端
**258** = **810**。`analyze` 与客户端 258 项本轮未改 Dart/Kotlin，沿用上一轮证据。

部署：`sync.js` `8f165297…`、`app-sync.js` `e78d5b3e…`、`ui.js` `1ed0de76…`、
`conflict.html` `b3f20448…`；`admin.html`/`app-admin.html` 未变。`server.py` 源码
`8105df2a…`（118128 B）**仍未重启加载**：`expectedUid`、整包回滚身份/owner、
删除重置标记、设备元数据入锁要等低峰窗口 `docker restart pvzge-save`。
oracle-sol 额度 06:16 重置后复核；复核通过前不关闭任务，也不清理
`zz-e2e-20261025`。残余 P2：B-49（冲突页不能表达玩家删除）、B-50（管理页手动
上传新建玩家不推进基准）、B-51（/restore 镜像/标记先于 manifest）、B-52（adopt
清整条 pending）。

## 2026-10-26 09:25 — 生产重启加载最新 server.py

用户确认在低峰窗口重启。执行 `docker restart pvzge-save`，容器 09:25:55 CST 启动，
`/healthz` ok。重启后验证：

- 临时用户 `zz-verify-20261026`（已清理）：`/save` 带 `expectedUid=uid-other` →
  **403 identity changed during save**，不写入；带 `expectedUid=uid-verify` → 200，
  `saved=['PvZ2_Settings']`、响应 `owner_uid=uid-verify`，`/load` 的
  `device.PvZ2_Settings.id = verify-dev`（设备元数据入锁生效）。
- 真实 `akadmin` 只读 `/load?gameVersion=0.16.1`：1 个玩家（NBMAN）、4 个键、
  `load_kind=exact`；`PvZ2_PlayerProperties.json`/`profiles.json` mtime 仍为
  10-25 22:58，未被读操作改写。
- `test-cloud-saves.sh` 重启后 **111 通过 / 0 失败 / 0 跳过**。
- 源码 `8105df2a…`（118128 B）；回滚备份 `/tmp/opencode/server.py.before-review2`
  （112544 B，第五轮前源码）。

B-45 关闭。剩余：oracle-sol 最终复核（已提交）、临时 E2E 用户清理、APK/Windows 重建、
B-49..B-52 的已知边界。

## 2026-10-26 10:20 — oracle-sol 最终复核修复（8 类 P1 中 7 类）

oracle-sol 判定上一版不可交付，给出 8 类 P1。本轮按文件分工修复并补断言：

1. **接管失败仍发布基准 / 运行期 adopt 不换 epoch**：`takeOverDocument` 增
   `force`；generation 写失败返回 false + `takeoverFailed`，启动恢复只落地
   内容、不发布基准/不装 hook（`syncDisabled` + toast）；运行期「用云端存档」
   强制开新 generation；已接管且 generation 有效时重复调用视为成功。
2. **换号目标账号恢复不完整**：`switchUser` 改为归档→清空→恢复游戏键/状态/
   目标 pending→逐项读回；任一失败回滚旧账号内容与 pending，目标归档成功
   后才删。接管 carry 失败时旧槽是唯一副本，换号会归档/回滚它。
3. **管理页 A 数据 + B 身份**：点击时同时捕获 data、`__pvzSyncUser`、
   `__pvzSyncGeneration`；`/load` 预检检查 `r.ok`，返回后与 `/save` 发送前
   各复核；`expectedUid` 仍用预检 uid。
4. **写后补偿不构成 CAS**：不再把 prev 写回；只有当前值仍是本次写入时才删，
   并写 `__pvzResync` 指纹（含内容哈希）；启动按云端重建，pending 不同则
   保留重放。真串行化仍缺（B-53）。
5. **采用云端写失败仍推进基准**：`applyAdoptedCloud` / `applyCloudSave` 写
   游戏键后读回；失败保留 marker/pending、不写 meta/基准、不 reload 成半套用。
6. **版本保护不隔离账号/ generation 槽**：`local_save_guard.dart` 备份键改为
   `账号+版本`，版本变化归档所有 `__pvzPending:<gen>`，恢复时并回基础队列；
   `__pvzPendingGv` 随版本归档/恢复，缺失时补写。
7. **降级 pending 被 migrated 搬运**：sync 新增 `__pvzPendingGv` 与方向比较，
   降级全丢、升级只丢 exact；版本保护同时把高版本槽移出活动区。
8. **/load 旧内容 + 新基准**：每个 key 的读取、stat mtime/纳秒版本、meta/
   回滚事件都在同一把 `save_lock` 内；`load_players` 加 `_lock_held` 避免
   flock 重入。另修 P2：`restoredProfileEvents` 毫秒级事件（连续 A/B 不再
   只看到最后一个）、tombstone 取消 100 条截断、空档弹窗 `esc()`。

实测：sync-offline **287/0**（Web 与 App 各一遍）、save-versions **159/0**、
cloud-saves **115/0/0**、concurrency 28/0、sync-live 9/0、admin 19/0、
local-save-guard **42/0**、game-host-contract 76/0、`flutter analyze` 无告警。
服务端 **617** + 客户端 **285** = **902**。

部署：静态 2026-10-26 10:08 已部署，`deploy-static.sh --check` 9 项全 ok
（sync.js `d6d94c8f…`、app-sync.js `34c322bd…`、ui.js `aaa0ca2e…`、
app-ui.js `acf42fad…`、admin.html `06447169…`、app-admin.html `8285f616…`、
conflict.html 未变）。`server.py` `5b5bf221…`（125080 B）已在本机 8093 临时
实例跑 159/28/9/19，但**生产容器仍跑 09:25 的旧进程**，需低峰重启加载。
残余 P1：B-53（多标签页无真串行化）。B-49..B-52 仍为已知边界。

## 2026-10-26 10:10 — 生产重启加载 5b5bf221

用户确认白天重启。`docker restart pvzge-save` 后容器 10:10:45 CST 启动，
`/healthz` ok，容器内 `/app/server.py` sha256 `5b5bf221…`。重启后验证：

- 临时用户 `zz-verify-20261026b`（已清理）：`expectedUid` 不一致 → 403
  `identity changed`；一致 → 200 `saved=['PvZ2_Settings']`。
- 真实 `akadmin` 只读 `/load?gameVersion=0.16.1`：1 个玩家（NBMAN）、4 个键、
  `load_kind=exact`、`restoredProfiles=[]`；`profiles.json`/玩家镜像 mtime 仍为
  10-25 22:58。
- 临时用户 `zz-restore-ev-20261026`（已清理）：两份玩家历史连续 restore A、B，
  `/load` 的 `restoredProfiles` 同时包含两份，`at` 毫秒级不同
  （1792980700068 / 1792980700099），证明不再只保留最后一个。
- `test-cloud-saves.sh` 重启后 **115 通过 / 0 失败 / 0 跳过**。
- 回滚备份：`/tmp/opencode/server.py.before-0626-restart`（8105df2a…，118128 B）；
  更早的 review2 备份仍在。

## 2026-10-26 11:05 — 第八轮：二次复核后的手动修复与手工复核

用户要求本轮不再调用 oracle-sol，由 orchestrator 逐段手工复核。二次复核共列
9 条 P1 + 1 条 P2，本轮修掉 8 条 P1 与 P2-1：

1. 单玩家回滚接管失败：不发布新 revision/seen/pending，进入停用。
2. 换号 `__pvzSyncUser` 写后读回，失败整体回滚旧账号（含账号标记）。
3. guard 只归档当前 generation 槽；无主槽不读不归档不删。
4. 账号归档键加 gameVersion；低版本不恢复高版本账号内容。
5. `writePendingRaw` 不再改写 `__pvzPendingGv`；迁移/carry 保留来源版本。
6. guard 三类归档全部读回确认；任一失败不清源、不推进上下文，并阻断目标
   版本读取/写入游戏键（读/写门闩 + `window.stop()` + 提示）。
7. adopt 只在全部内容确认后删旧 pending；失败保留 marker/旧槽。
8. `syncDisabled` 仍装只记本机 pending 的 local-only hook。
9. 管理页迟到 ACK 写共享基准前三次复核身份快照（P2-1）。

额外手工复核发现并修：恢复/采用云端部分写失败时回滚已落地键；恢复写循环
中途被接管直接 reload，不再带着半状态启动。

验证（真跑）：sync-offline Web/App 各 **339/0**、save-versions **159/0**、
cloud-saves **117/0/0**、admin **21/0**、sync-live **9/0**、concurrency
**28/0**、guard **65/0**、game-host **76/0**、local-server 52/0、
storage-migration 63/0、desktop-zip 11/0、update-manifest 32/0、
check_cloud_saves 9/0；`flutter analyze` 无告警。总 **981**（服务端 673 +
客户端 308）。

静态 **2026-10-26 10:57 / 11:04** 部署，`deploy-static.sh --check` 9 项全 ok：
`sync.js` `d9dc302c…`（138178 B）、`app-sync.js` `4c409359…`、
`ui.js` `083183f0…`、`app-ui.js` `963ac27c…`、`admin.html` `31435147…`、
`app-admin.html` `dcf3b2a2…`、`conflict.html` 未变。服务端 `server.py`
`5b5bf221…` 已于 10:10:45 加载，本轮无需重启。

剩余唯一 P1：**B-53**（Web 多标签页无真正跨上下文互斥）。App/Android 有
`GameActivity.running` 单实例门禁；Web 的完整方案需要入口页持 Web Locks、
游戏放在 iframe，不能在现有同步注入架构里打补丁。另有 B-58..B-62 五个 P2
边界已记入 backlog。

## 2026-10-26 11:45 — 第九轮：Web 单标签页门闩 + 删除在线游玩

用户接受「Web 同一浏览器只开一个游戏标签页」并要求代码强制，同时删除启动器
在线游玩模式、只保留本地资源包。

**Web 单标签页**：`sync.js` 末尾用 `navigator.locks` 获取 `pvzge-game-writer`
生命周期锁（持有到页面卸载）。第二个标签页拿不到锁就 `window.stop()` + 覆盖
提示，不再产生游戏写入；锁回调前的游戏键写入进内存缓冲，grant 后经上传 hook
落盘，blocked 后丢弃；`guardedRawWrite` 检查 `window.__pvzWriterBlocked`；
缓冲 clear 先清后补写。无 Web Locks 的 Web 主机 fail closed；App/本地回环
origin 按单实例放行。断言 sync-offline `[80]-[85]`，Web/App 各 **381/0**。

**删除在线游玩**：`PlayMode`/`playMode`/`desktopOnlinePort`、在线资源代理/
心跳/桌面 upstream/在线会话 origin 全部移除；只保留本地资源包。登录、云存档、
资源下载、APK/Windows 更新检查保留。旧 JSON 的 `playMode:"online"` 与
`desktopOnlinePort` 显式忽略，账号/服务器/令牌/主题/语言/`desktopLocalPort`
保持原值；存档页默认本地分区，手动切在线分区保留；`_ensureOnlineGameVersion`
改名 `_ensureRemoteGameVersion` 供在线分区取版本。Android 删除
`OnlineGameResourceClient`/`OnlineSessionHeartbeat` 及对应 JVM 测试。

验证：`flutter analyze` 无告警；local-server **42/0**、storage **63/0**、
desktop-zip **11/0**、game-host-contract **73/0**、update-manifest **32/0**、
check_cloud_saves **9/0**（在线段缺 token 跳过）、guard **65/0**；
Android `:app:testDebugUnitTest --rerun-tasks` 10 类 / **46/0**；
sync-offline **381/0**（Web/App）；cloud-saves **117/0/0**。
总基线 **1010**（服务端 715 + 客户端 295）。静态 11:27 部署，
`deploy-static.sh --check` 9 项一致；`server.py 5b5bf221…` 无需重启。

B-53 关闭（单标签页门闩）；B-01/B-32 随在线玩法删除关闭；B-33 改为本地资源包
真机复测；新增 B-63（旧 `__sync_native_token` 清理边界）。APK/Windows 包未重建。

## 2026-10-26 13:05 — 第十轮：Web 顶层锁 + 游戏 iframe，修 oracle-sol P1

`oracle-sol` 对第九轮给出「不可交付」：5 条 P1，核心是 Web 锁在 `sync.js` 末尾，
第二个标签页在拿锁前已经 `/load`、恢复、推进 generation，正在游玩的页未上传
改动会被判废。第九轮的门闩只挡游戏键，挡不住 boot 本身和 blocked 页的迟到
ACK/失败重试。

**P1-1**：Web 顶层不再跑同步 boot。`sync.js` 先请求 `pvzge-game-writer`；
`lock === null` 就 `window.stop()` + 覆盖提示，不 `/load`/不创建 iframe。
grant 后创建同源 iframe，游戏在子 frame 执行同一份 `sync.js`（子 frame 识别
父页 `__pvzWriterHost`，不再争锁）；父页持锁到卸载。App/本地回环走原同步
boot。断言 `[86]`：顶层不 `/load`、gen 不变、第二个标签页无 iframe/无上传。
**P1-2**：门闩 pending 阶段所有键进影子区；blocked 后 `send/requeue/pump/
flush/drainPending/ACK/onerror` 全部拒绝，定时器清空。断言 `[87]`。
**P1-3**：运行期 `applyCloudSave()` 逐键/meta/玩家基准/pending 快照，任一步
失败回滚；回滚再失败就置 `__pvzRuntimeWritesBlocked` 停止本局写档。断言 `[88]`。
**P1-4**：`_ensureRemoteGameVersion` 捕获令牌+服务器+代际，写 `_remoteManifest`
和调 `_handleTokenRejected` 前复核；换服/换号清空 `_remoteManifest`。
**P1-5**：guard 原子写（临时→读回→rename→再读回），失败抛出阻止启动；新增
`localSaveGuardRequired` 贯通 Dart→Kotlin，Android required 时缺失/空白/读取
失败 fail closed。
**P2-1**：`clear()` 后未重写的键读 null。
**P2-2**：`APP_SYNC` 现在切换整套 411 条用例的源，删掉 `|| true`。

验证（真跑）：`flutter analyze` 无告警；sync-offline **411/0**（Web/App 各
一遍）、save-versions **159/0**、concurrency **28/0**、sync-live **9/0**、
admin **21/0**、local-server **42/0**、storage **63/0**、desktop-zip **11/0**、
game-host-contract **83/0**、update-manifest **32/0**、cloud-saves 离线 **9/0**、
guard **65/0**；Android JVM **46/0**。总基线 **1050**（服务端 745 + 客户端
305）。Playwright 冒烟：顶层锁 grant→iframe、子 frame boot、第二页 blocked；
游戏页在 iframe 中 canvas 1280×720。

## 2026-10-26 13:40 — 发布 hlh.25，补 B-65

`tools/bump-version.sh` 把版本从 `0.9.0-hlh.24+90024` 升到 `0.9.0-hlh.25+90025`，
两个产物都从最终代码重建：

- APK：58,652,112 B / `f2cfa15e…`，versionCode 90025，`apksigner` v1+v2+v3 通过；
  已发布到 `/var/www/pvzge-res/apk/`，`apk/manifest.json` latest 指向 hlh.25。
- Windows x64：190,024,416 B / `ca9e0e82…`，在 Windows 主机用
  `tools/build-windows.ps1` 重建；已发布到 `/var/www/pvzge-res/win/`。
- GitHub 私有仓 Release `v0.9.0-hlh.25`，四个资产（APK、APK sha256、zip、
  zip sha256）上传成功。

B-65 关闭：iOS `GameHostController` 与 OHOS `GamePage` 现在读取
`appRoot/__local_save_guard.js` 并追加到 document-start；`localSaveGuardRequired`
两端与 Dart/Android 同口径（旧 JSON 默认 false），required 时缺失/空白/读取失败
阻止启动。`check_game_host_contract` 新增 11 条源码契约（83→94）。本机无
Xcode/OHOS SDK 与设备，两端未编译、未实机，残余风险已写进 backlog。

客户端复跑：`flutter analyze` 无告警；local-server 42、storage 63、desktop-zip 11、
game-host-contract 94、update 32、guard 65、cloud 离线 9（在线 25 用临时账号跑过）、
Android JVM 10 类 / 46 tests / 0 failures。总基线 **1061**（服务端 745 本轮未改，
沿用 12:36/13:05 实跑；客户端 316）。

真实 authentik 登录态 Web E2E：顶层 `lock=granted`、`host=true`、iframe 存在；
子 frame `canvas=true`；第二个标签页 `lock=blocked`、无 iframe、无 `/load`，
日志 `second game tab blocked (busy)`。临时账号 `zz-e2e-20261025` 已删除，
临时云存档移入 `/home/hlh/pvzge-backups/zz-e2e-20261025-20261026-125912`，
5 个临时令牌与锁文件已清理。

仍未完成：B-33 Android 真机首屏/退出；B-64 完整一局人工验收；
真实 `akadmin` 冲突选择。

## 2026-10-26 13:42 — 统一 Web/App 游戏内存档面板的「上传本机」

用户反馈手机端游戏里的存档面板没有「上传本机存档」，怀疑 Web/App 是两套存档。
实际是同一份服务端数据、同一份 `admin.html` 生成物；差异只在 App 面板 iframe 是
服务器 origin，读不到本地资源包 origin 的 localStorage，所以按钮被
`if(window.__PVZGE_APP__)` 隐藏。

改法：按钮上移到游戏页自己的面板标题栏（`ui.js`），点击调用
`window.__pvzManualUpload()`（`sync.js`）。上传走现有 `send(payload, true)` 合并
通道——`baseVer`/`baseMtime`、冲突检测、玩家回填、基准推进都在；**不是**
`forceUploadLocal()`，不会把云端有、本机没有的玩家当删除。结果用
`pvz-save-manual-upload-done/failed` 只回传一次；iframe 内嵌时隐藏重复按钮，
直接打开 `/_save/admin.html` 仍保留原按钮。

验证（真跑）：`node --check` 通过；`test-sync-offline` Web **441/0**、App 生成物
**443/0**；`test-admin-baseline` **21/0**。`deploy-static.sh` 已部署，
`--check` **9/9**；部署后 `test-cloud-saves.sh` **117/0/0**。`server.py` 未改、
未重启。手机端不需要重新装 APK：`app-sync.js`/`app-ui.js` 每次启动游戏时从服务器
拉取。

残余：25 秒后返回的上传结果不会再弹提示（后台仍会推进队列/基准，刷新面板可见）；
B-33/B-64 与 iOS/OHOS 实机验证仍未做。

## 2026-10-26 15:23 — Web 登录后黑屏热修：撤掉游戏 iframe，改回顶层文档 + pass 交接

现象：线上 Web 登录后整页全黑，游戏进不去。手机/PC 都一样。

定位（真实 Chromium 156，非 localhost 域名，注入脚本与生产同一份）：第十轮把游戏装进
同源 iframe，父文档在 `</head>` 就 `window.stop()`，`document.body` 从未生成，整棵文档树
**rAF 一次都不触发**（2 秒 0 次回调）；iframe 里 cocos 资源全部 200 加载完，但
`cc.game.isPaused()===true`、`director.getTotalFrames()===0`、`getScene()===null`。
同一份页面在顶层文档直接跑是 `frames=412 / mainScene`。线上 14:43 日志也吻合：游戏资源
全部 200 之后没有任何后续请求。**不是**账号、存档或资源问题；单测（jsdom）也测不出来。

改法：删掉 iframe 宿主，改为写者资格传递（pass）——公网 Web 无 pass 的顶层只做一次极短
交接（`ifAvailable` 拿 `pvzge-game-writer` → `sessionStorage` 写一次性 pass →
`window.stop()` → `location.replace(location.href)`，锁持有到卸载）；带 pass 的顶层消费
pass 后走原顶层 boot（与 App/桌面同一条路径）。锁被占时渲染全屏提示且**不 stop**，并提前
吞掉 4 个存档键的 `setItem/removeItem`；pass 页在 `armWriterGate` 拿不到锁时
250ms×8 重试，躲开旧文档卸载与锁释放的竞态。

验证（真跑）：`test-sync-offline` Web **473/0**、App 生成物 **475/0**、
`test-admin-baseline` **21/0**、`deploy-static --check` **9/9**、部署后
`test-cloud-saves` **117/0/0**。真实浏览器：修复后 `iframes=0`、`frames=463`、
`scene=mainScene`、`writerLock=granted`；第二标签页提示层 1100×673 可见、不 boot、
存档键写入被吞。静态已部署；`server.py` 未改、未重启，nginx 未改。

残余：真实账号完整一局（音频/全屏/触控/退出/云上传）仍需人工；公网 Web 首次进入多一次
导航（交接页）；旧标签页必须硬刷新才会拿到新 `sync.js`。

## 2026-10-27 — Windows 启动必崩（MissingPluginException）修复与 hlh.26

用户装了 Windows 包，一启动就弹「应用初始化失败」。日志：

```
MissingPluginException(No implementation found for method incomingZip on channel
io.github.dey410.gardendlessloader/resource_zip_importer)
  at app_controller.dart:1258  (_resourcePickerService.incomingZipName())
```

根因：`resource_zip_importer`、`shortcuts`、`external_browser` 三个平台通道只在
Android/iOS/鸿蒙实现，`windows/runner` 里一个平台通道都没有。桌面端 `invokeMethod`
必抛 MissingPluginException，而这三行正好在 `initializeCore()` 末尾，被
`initialize()` 的兜底 catch 接住 → 整页初始化失败。该机 `slot-a`/`slot-b` 空、
`downloads` 里只有一个没有 EOCD 的 14 MB 半包，说明这台 Windows 从来没成功
初始化过（这个坑从 10-18 加入通道的那次提交就存在）。

改法：
- `ResourcePickerService.incomingZipName/discardIncomingZip`：非移动端直接返回
  null / 空操作；通道缺失按「没有待处理 ZIP」处理。
- `ShortcutService.take/publish`：桌面端直接返回，缺失通道忽略。
- 新增 `ExternalUrlService`：Windows `cmd /c start`、macOS `open`、Linux
  `xdg-open`、移动端走 `external_browser` 通道；`openTokenIssuePage` 与 UI 的
  公告/更新链接都改走它，顺带修掉 Windows「点链接没反应」。

验证：`flutter analyze` 无告警；新增 `tool/check_desktop_channels.dart` **21/0**；
既有客户端套件不变（game-host-contract 94、local-server 42、storage-migration 63、
update-manifest 32、cloud-saves 9、local-save-guard 65）。基线 1123→**1144**
（服务端 807 + 客户端 337）。

## 2026-10-27 04:30 — 发布 0.9.0-hlh.26（Windows 启动崩溃修复）

- APK `0.9.0-hlh.26`：58,652,110 B，sha256 `ac761fe7…fb40b2`，v1/v2/v3 全签。
- Windows x64 zip：190,021,420 B，sha256 `4c0774d6…252a26`，`unzip -t` 无错。
- 两个分发清单 `latest` 均为 `0.9.0-hlh.26 (90026)`；GitHub Release
  `v0.9.0-hlh.26` 四个资产，digest 与本地一致。
- 测试基线 1123 → **1144**（服务端 807 + 客户端 337，新增 desktop-channels 21）。
- 代码仍未提交/推送（与 hlh.25 相同处理）。

## 2026-10-27 — Windows 更新结果回执 + 下载目录默认位置（待发 hlh.27）

用户实测反馈两点：①点「退出并自动更新」后应用直接消失，没有进度也没有结果提示，
无法判断是否更新成功；②下载目录跟着资源根走，资源根被设成 `...\downloads` 时会出现
`...\downloads\downloads\`。

更新回执（B-67）：
- 脚本新增 `-Result <json> -FromVersion -ToVersion`，**每条**退出路径写
  `{status: applied|rolled-back|failed, code, message, fromVersion, toVersion, logFile, at}`，
  失败路径一律重新拉起加载器（原来 exit 2/3/5 会把用户晾在空桌面）。
- Dart 退出前写 `windows_update_result.json`（pending），启动时
  `_consumeWindowsUpdateResult()` 读一次、删除、转成提示：
  `applied` → 「已更新到 X」；`rolled-back`/`failed`/`pending` → 带下一步动作的失败提示；
  同时写 `windows_update_result_consumed` 日志（含 logFile）。
- 退出前把 installing 状态刷出去并延迟 900 ms，设置页可见「正在退出并安装更新…」。

下载目录（B-68）：
- 桌面端默认 `<exe 目录>\downloads`（创建后真写探测，不可写退回资源根）；移动端不变。
- 更新脚本的备份与回滚 robocopy 增加 `/XD "<install>\downloads"`：否则上 GB 的资源包
  会被整份备份，回滚的 `/MIR` 还会把它删掉。

验证（本机，真跑）：`flutter analyze` 无告警；`check_update_manifest` **42/0**（32→42）、
`check_desktop_channels` 21/0、`check_game_host_contract` 94/0、`check_local_server` 42/0、
`check_storage_migration` 63/0、`check_cloud_saves` 9/0、`check_local_save_guard` 65/0。
基线 1144→**1154**（客户端 337→347）。

未做：Windows 机器已关机，hlh.27 的构建、实机三路径（成功/失败/回滚）验证、发版都待机器回来后执行。

## 2026-10-27 — 更新链路 Debug：手动审计出 9 处失败路径缺陷

Windows 关机，改用静态审计 + 本机可执行断言把「更新 → 重启 → 提示」这条链路的
失败分支逐个走了一遍，修掉：

1. **未预料的异常没有回执**：杀软拦截、句柄占用、属性访问被拒都会让脚本直接中止，
   而应用早已退出 → 用户面前空桌面、pending 回执永远留着。→ 全脚本包一层
   `try/catch`，写 `failed/unexpected` 回执并重启，`exit 6`。
2. **杀残留进程会打断脚本**：`Get-Process | Where-Object { $_.Path ... }` 对受保护进程
   读 `.Path` 抛 Access denied，配合 `$ErrorActionPreference='Stop'` 直接终止。→ 该段
   整体降级 `SilentlyContinue`，结束后恢复。
3. **robocopy 缺失/被拦**：`Start-Process robocopy` 抛错同样中止。→ `Invoke-Robocopy`
   包 try/catch，返回 16（按失败处理，走备份失败分支）。
4. **写日志失败会打断更新**：`Say` 里的 `Add-Content` 在临时目录不可写时抛错。→ try/catch。
5. **重启无重试**：刚复制完/回滚完，exe 可能还被上一次进程占着。→ 5 次、每次间隔 1 秒。
6. **`New-Object System.Text.UTF8Encoding($false)`** 依赖位置参数绑定，PS 5.1 上不直观。→ `::new($false)`。
7. **`Expand-Archive` 太慢**：400 MB+ 解压要几分钟且全程无输出，用户以为卡死。→
   `[System.IO.Compression.ZipFile]::ExtractToDirectory`（目标目录不预创建）。
8. **code 不一致**：日志/提示用 `status.name` 生成 `windows_update_rolledBack`，而
   `userErrorCatalog` 里是 `windows_update_rolled_back` → 回滚提示里查不到「下一步」。
   → `WindowsUpdateOutcomeStatus.logCode` 统一，并加断言。
9. **pending 回执没撤**：`Process.start` 失败时 pending 已写、脚本没跑 → 下次启动误报
   「更新被中断」。→ catch 里删除回执。

可执行断言：
- 新增 `tool/check_windows_update_result.dart` **38 项**（四态解析、坏 JSON/数组/缺 status
  返回 null、BOM 容错、大小写不敏感、数字字段转文本、多余字段忽略、logCode 与 catalog 对账）。
- `check_update_manifest` 32→**49**（补：兜底 catch、受保护进程降级、robocopy 兜底、
  日志容错、重启重试、ZipFile、pending 撤销）。
- 其余不变：desktop-channels 21、game-host-contract 94、local-server 42、storage-migration 63、
  cloud-saves 9、local-save-guard 65。客户端基线 337→**392**，总 **1199**。

另外记录一条待验证项 **B-69**：Windows 打开链接用的 `cmd /c start` 对含 `&` 的 URL
会被 cmd 当命令分隔符（既不完整也不安全），等 Windows 回来实测后再决定改 `rundll32`
或自己做转义——不在无实机的状态下盲改。

## 2026-10-27 — hlh.27 发布：更新可见化 + 四类实机缺陷

Windows 主机回来后，先做「更新脚本实机验证」，再发版。发的是 hlh.27：
APK 58,652,116 B / `c044ffcb…`，Windows zip 190,028,036 B / `28b6f655…`，
两份服务端清单 latest 均为 0.9.0-hlh.27（90027），GitHub Release `v0.9.0-hlh.27`。

Windows 实机验证（`tools/test-windows-updater.ps1`，**52/0**）覆盖七条路径 +
正式发布包。验证过程中查出四个本机静态审计发现不了的问题：

1. **robocopy 永久挂住**（最严重）：默认「重试 100 万次 × 等 30 秒」。目标文件
   被占用（CEF 没退干净、杀软扫描）时脚本不报错、不超时、永远不结束，用户看到
   的就是「应用没重启、也没任何提示」——正是这次要修的症状的另一个成因。
   已改为 `/R:2 /W:1`，两次失败即回滚。
2. **备份失败留半成品**：`/MIR` 备份中途失败会留下几百 MB 的 `<安装>.backup`，
   安装目录其实没动过。现在删掉。
3. **回滚成功后备份不删**：同样几百 MB 垃圾。现在删；而**回滚失败时必须保留**
   （那是用户唯一完整的旧版本），提示里直接给出备份路径。
4. **`cmd /c start` 截断 URL（B-69）**：起本地 HTTP 服务器抓请求，
   `http://127.0.0.1:<port>/game?uid=42&profile=slots-1&ver=hlh.26` 经
   `cmd /c start` 只有 `/game?uid=42` 到达；`&` 之后被 cmd 当成独立命令执行。
   改为 `rundll32 url.dll,FileProtocolHandler`，兜底 PowerShell
   `Start-Process -FilePath '<url>'`；两条路径实测都送出完整 URL。

另外确认两件与「能否更新成功」直接相关的事：
- `Expand-Archive` 解正式包要几分钟且全程无输出（用户以为卡死）；换成 .NET
  `ZipFile::ExtractToDirectory` 后同一份包 **8.7 秒**。
- Compress-Archive 生成的 zip 条目用反斜杠分隔，.NET 的 `ExtractToDirectory`
  能正确吃下（正式包实测解出 `data\flutter_assets`、`libcef.dll`）。

新增工具：
- `tool/print_windows_updater.dart`：把更新脚本按运行时同款编码（BOM+CRLF）导到磁盘。
- `tool/check_windows_update_result.dart`：回执 JSON → 四态纯映射，**38** 项。
- `tools/test-windows-updater.ps1`：Windows 实机更新路径，**52** 项。
- `tools/smoke-windows-build.ps1`：发布包解压后启动冒烟，**6** 项（hlh.26 的
  启动崩溃只有跑起来才能发现）。

`handoff.sh verify` 的 PowerShell 编码检查从「只查 build-windows.ps1」改成
遍历 `tools/*.ps1`——新增的两个脚本都要求 BOM+CRLF。

改动后：`flutter analyze` 无告警；客户端套件
update-manifest 53、windows-update-result 38、desktop-channels 23、
game-host-contract 94、storage-migration 63、local-server 42、
local-save-guard 65、cloud-saves 9（离线）全绿。基线 1199 → **1205**
（服务端 807 + 客户端 398）。`verify` 25/0。

未做：用户实机走一遍「设置 → 检查更新 → 下载 → 退出并更新 → 重启看提示」；
B-33（Android 本地资源首屏）仍需真机；iOS/OHOS 未编译；两仓改动仍未提交。

本轮服务端未改代码，但为对齐基线仍复跑了四套：`test-sync-offline` 473、
`test-save-versions` 159、`test-concurrency` 28、`test-admin-baseline` 21，
外加对已部署实例的 `test-cloud-saves` 117，全部 0 失败（合计 798）。
`test-sync-live` 9 项需要临时实例（`DATA_DIR`+非默认端口启动 server.py），
本次环境不允许起后台服务，沿用 hlh.26 期实机结果，未复跑。

### 2026-10-27 用户机器从 hlh.25 升到 hlh.27（SSH 原位替换，未点界面）

用户的加载器装在 `D:\Program Files\gardendless-loader`（快捷方式指向它），版本
`0.9.0-hlh.25+90025`；资源根设成 `<安装目录>\downloads`，里面还有一层旧的
`downloads`（就是 B-68 的 `downloads\downloads`），7 个文件 699 MB。

考虑到旧版本内置更新用的是修复前的脚本（无回执、失败不重拉、robocopy 无重试上限），
这次没有让用户点界面，而是用新增的 `tools/upgrade-windows-install.ps1` 在前台做：
暂存解压 → `/MIR` 备份（`/XD downloads`）→ `/E` 覆盖 → 版本与 downloads 校验 →
12 秒启动冒烟。**10/10 通过**：

- exe `0.9.0-hlh.25+90025` → `0.9.0-hlh.27+90027`
- downloads 7 个文件 / 699 MB 前后一致
- 启动后 12 秒仍在运行，事件日志无崩溃记录
- 备份 `D:\Program Files\gardendless-loader.backup`（430 MB，不含 downloads）——
  用户确认新版本可用后已于同日删除，释放 429.8 MB；安装目录与 downloads 均完好

顺带确认：hlh.27 的默认下载目录 `<exe 目录>\downloads` 正好等于该用户现有的资源根，
位置不变，不需要迁移。

残余：用户还没走过一次**新**更新流程（检查 → 下载 → 退出并安装 → 重启看到结果提示），
这条链路要等下一版发布时才能实际触发；`tools/upgrade-windows-install.ps1` 的自动化
用例也还没单独补（目前靠这次实机执行当证据）。

## 2026-10-27 — hlh.28：Windows 全屏（游戏内全屏开关终于生效）

用户反馈：Windows 端没有全屏，游戏设置里选「全屏」没有任何变化。

查下来是三层原因叠加，缺一层都不成立：

1. 游戏把宿主当 Electron：资源包里的 `tmppatch.js` 自造 `window.electron`，
   设置里的全屏最终调 `document.documentElement.requestFullscreen()`。
2. 桌面加载器是 **CEF 离屏渲染**（画面贴成 Flutter 纹理）。离屏模式下 HTML5 全屏
   不会改变窗口；插件源码里 `grep -i fullscreen` 0 命中，没有全屏回调可接。
3. `windows/runner` 一直是 Flutter 模板，启动器自身没有任何窗口级全屏能力。

修法（宿主侧做全屏，页面侧只负责转发）：
- 原生窗口通道 `io.github.dey410.gardendlessloader/window`：`setFullscreen` 记下
  `GWL_STYLE/GWL_EXSTYLE/WINDOWPLACEMENT` → `WS_POPUP` + `MonitorFromWindow
  (MONITOR_DEFAULTTONEAREST).rcMonitor` → 退出时 `SetWindowPlacement` 精确还原。
- F11 在 `MessageHandler` 里**先于** Flutter/CEF 拦下（否则按键被页面吃掉），
  状态用 `InvokeMethod("onFullscreenChanged")` 推回 Dart。
- 注入脚本把 `requestFullscreen`/`exitFullscreen`/`webkit*` 转给
  `window.gardendlessDesktop`（Dart JS 通道），并伪造 `document.fullscreenElement`
  ——不伪造的话游戏用 `electron.isFullscreen()` 判断会永远「不是全屏」，第二次点
  还是进入。宿主改状态时用 `__gardendlessFullscreen.apply` 回灌。
- 游戏页：每次 `onLoadEnd` 重装桥（reload 会清掉 JS 通道）、工具栏加全屏按钮、
  离开页面强制退出全屏。

验证：
- `check_desktop_channels` 23→**38**；新增 `check_fullscreen_script` **23**（Node 假 DOM
  跑「进入/退出/再进入」、F11 回灌、无通道不假装成功、重复注入、webkit 前缀）。
- 新增 `tools/test-windows-fullscreen.ps1` **13**：给真实窗口 `PostMessage(WM_KEYDOWN,
  VK_F11)`，实测 `style 0x4CF0000 → 0x96000000`(WS_POPUP)、`rect 10,10 1044x720 →
  0,0 1024x768`（显示器矩形），退出后逐字节还原，连续切换 3 次不漂移。**用发布包跑的**。
- 顺带确认：ssh 会话里 GUI 进程的窗口永远「不可见」（`Process.MainWindowHandle` 恒为 0，
  已发布版同样如此），所以测试改成按 PID + 窗口类名 `EnumWindows` 枚举隐藏窗口——
  样式与矩形仍然是真实的，验证照样成立。

发布：APK 58,652,221 B / `89a58a0b…`，Windows 190,082,846 B / `e419aca1…`，
两份清单 latest=0.9.0-hlh.28，Release `v0.9.0-hlh.28`。基线 1205 → **1243**。

遗留：游戏内点全屏（JS→Dart）这一段无法自动化，需用户点一次；多显示器/DPI 未覆盖。
另外构建期间踩到一次并发构建把 `dist` 里的 zip 写坏（同一文件被两个 build 同时写），
重跑后 `unzip -t` 通过——以后 Windows 构建不要并发跑。

## 2026-10-27 — hlh.29：自动更新真的会装了，而且看得见进度（B-71）

用户点「退出并自动更新」后：启动器立刻消失，没有进度窗口，没有重启，
日志页什么都没有，重启后还是 hlh.27。

先查真机状态，再查代码，最后用对照实验定位。事实链：

1. `D:\Program Files\gardendless-loader\gardendless_loader.exe` 仍是 hlh.27
   （11:39 那份，没被覆盖），`<资源根>/windows_update_result.json` 只有一份
   `pending`，`%TEMP%` 里**没有任何这次运行的 `gardendless-update-*.log`**
   → 更新脚本根本没有启动过。
2. 事件日志 13:42:49 有一条 `Application Error 1000`：`gardendless_loader.exe`
   `0xc0000409` / `ucrtbase.dll`，时间正好在 900 ms 延迟后的 `exit(0)`。
3. 对照实验（把 app 的启动代码抄成一个独立 dart 程序，跑在同一台机器、
   同一个带空格的路径上）：
   - `ProcessStartMode.detached` → 打印出 pid，但探针脚本**一行都没执行**、
     连日志都没创建（带空格与不带空格都一样）；
   - `ProcessStartMode.normal` → 参数完整送达，脚本正常执行；父进程
     `exit(0)` 消失 6 秒后，子进程仍然写出了文件。

结论：两条独立缺陷叠加。detached 在 Windows 上是空转（所以脚本从未跑），
`exit(0)` 又让进程 fail-fast 崩溃（所以用户看到「崩了」而不是「安静退出」）。

修法见 `07-backlog.md` B-71。要点：
- 普通模式启动 + 关 stdin + 读掉 stdout/stderr；参数拼装收进
  `WindowsUpdaterScript.start()`（应用与实机测试共用同一份）。
- 退出前 700 ms 存活校验：秒退就取消更新并显示错误，不再静默消失。
- 退出改走窗口通道 `quit`（原生 `PostMessage(WM_CLOSE)`），6 秒兜底。
- 更新脚本自带「正在更新」WinForms 进度窗口，等待期间泵消息；UI 失败只降级。
- 顺手修：`openWindowsUpdateFolder` 也用了 detached；`Invoke-Robocopy` 用
  `Start-Process -PassThru`（PS 5.1 不带 `-Wait` 时 `ExitCode` 恒为 `$null`，
  于是失败被当成成功、回滚分支永远不触发——测试用例 4/5 当时整段失效，
  这次自查时才发现，已改成 .NET `Process` 取真实退出码）。

真机验证（都用发布包）：
- `test-windows-updater.ps1 -RealZip` **63/0**：真实包 8.7 秒装完；
  第 9 例用 `dart run tools/windows_update_spawn_check.dart` 调生产代码启动，
  父进程 900 ms 后退出，脚本自己跑完 6.1 秒 → `applied`，并断言日志里没有
  `progress ui unavailable`（窗口真的建起来了）。
- 新增 `test-windows-quit.ps1` **5/0**：`WM_CLOSE` 后 15 秒内退出、退出码 0、
  **没有崩溃事件**、没有残留进程。
- `test-windows-fullscreen.ps1` **13/0** 回归。

一个误导性线索也记在这里：排查时看到两个 11:07 起常驻的 `CefViewWing` 进程，
一度当成崩溃留下的孤儿；实际是 **MuMu 模拟器** 的进程。本项目的 CEF 辅助进程
与主进程同名（`gardendless_loader.exe --type=...`），按进程名断言即可。

发布：APK 58,652,216 B / `f5d474b0…`，Windows 190,085,999 B / `6ec6235a…`，
两份清单 latest=0.9.0-hlh.29，Release `v0.9.0-hlh.29`。基线 1243 → **1259**。

用户安装（hlh.27 的更新器就是坏的，救不了自己）：用
`tools/upgrade-windows-install.ps1` 就地替换到 hlh.29，10/0；`downloads`
8253 个文件 / 2207.1 MB 前后一致；12 秒冒烟无崩溃事件；顺手删掉上次失败留下的
hlh.28 zip（181 MB）与 `apply-windows-update.ps1`。旧版本备份 440 MB 暂留。
