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
