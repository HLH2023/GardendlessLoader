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
