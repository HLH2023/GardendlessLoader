# 07 待办与已知缺陷

> 优先级定义：P0 = 影响核心功能或安全；P1 = 明显体验缺陷或有数据风险；P2 = 打磨。
> **修完一条就把它移到本文件末尾「已关闭」并写断言名**，不要直接删除（便于回溯）。

## P0

### B-01 安卓在线形态真机验证（已随在线玩法删除关闭，2026-10-26）
- 现状：`OnlineSessionHeartbeat` 现在每次 enter/leave 都写结构化日志
  （`game.heartbeat / heartbeat_sent|heartbeat_failed`，含 `statusCode`、`durationMs`、
  `phase`）；401/403 会停止心跳、写 `online_token_rejected` 并带
  `tokenRejected` 原因退回启动器；`GameActivity` 补了 paused/resumed/stopped 生命周期日志。
- 已完成：`docs/acceptance-android.md` 验收清单。
- 2026-10-26：用户决定删除在线游玩模式，本项不再适用；原生心跳/在线代理已删除。
- 断言：`tool/check_game_host_contract.dart` 的 `GameActivity 心跳回调里上报令牌失效` /
  `在线令牌失效时使用 TOKEN_REJECTED`。

### B-02 资源包管理 UI 双端一致性（门禁已补，等真机复核）
- 事实核对（2026-10-25）：本版本**没有**「多包安装列表 / 手动切换 / 删除某个包」的 UI，
  导入即「安装 + 校验 + 原子切换」，旧槽自动清理。因此不存在「误删正在用的包」的入口；
  原条目描述的删除按钮并不存在，是文档与实现的偏差，不是缺失功能。
- 已修：迁移与切形态原先只查四个内存门禁，不查持久化事务状态。崩溃恢复窗口
  （`manifest.transactionState` 停在 extracting/validating/readyToActivate）里仍可迁移，
  会把半成品槽整体搬走。现在 `resourceTransactionBusy()` 统一判定，
  迁移/切形态/导入三处都查。
- 剩余：真机按 `docs/acceptance-android.md` 第 4 节走一遍「迁移中/导入中」互斥。
- 断言：`tool/check_storage_migration.dart` 的「事务状态 <state> 的忙判定」7 条
  （覆盖全部 `TransactionState` 枚举值）。

## P1

### B-22 Windows 桌面端 localStorage 仍缺磁盘持久化（需 Windows 实机 + 原生补丁）
- 现象：`webview_cef 0.6.2` 的 `startCEF()` 未设置 `CefSettings.cache_path`，
  默认 request context 不带磁盘缓存。只修稳定端口能保证 origin 不变，
  但重启后 CEF 是否把 localStorage 落盘仍取决于插件实现，本机无法验证。
- 已完成：`LocalResourceServer.start(port:)` + 首次分配后持久化的
  `desktopLocalPort/desktopOnlinePort`；本地/在线现在是两个不同且稳定的
  origin（`http://127.0.0.1:<port>`）。
- 剩余：给 webview_cef 做一个小型受版本控制的原生 fork（设置 AppSupport 下的
  固定 cache_path，退出时完成 CefShutdown 落盘），在 Windows 实机上断网验收：
  离线写 A → 退出重开仍是 A；在线写 B → 回本地仍是 A；升级安装不丢。
- 判据：`tool/check_local_server.dart` 的固定端口/占用拒绝 9 条已通过；
  Windows 实机三条人工断言通过后才可关闭。

### B-23 authentik uid 目前只做绑定与展示，目录仍按 username
- 现状：`identity.json` 把 username 目录绑定到 uid，同名不同 uid 直接 403；
  `X-Authentik-Uid` 已由 nginx 转发，令牌记录也带 uid（`REQUIRE_UID=1` 时
  旧令牌要求重新登录）。
- 剩余：把权威存储目录迁到 uid（或 uid 哈希），由运维在冻结写入后
  dry-run → 复制 → 校验 → 原子切换；旧目录保留只读。
- 为什么现在不做：迁移真实 `saves/akadmin` 需要部署窗口与备份，
  不能由客户端构建顺手改。当前绑定层已经阻止「同名认领」。

## P2

- B-10 `pvzge-auth` 容器已停但 compose 定义仍在（宿主重启可能复活）。
- B-11 1Panel `IpWhiteList` 仍是内网段白名单（安全面收窄）。
- B-12 new-api 日志 3.1 GB 未清（磁盘）。
- B-13 GitLab 明文 DB/SMTP 密码待轮换。
- B-14 代理池 `.22` 的 Anthropic 规则固定路由到失效美国组（与客户端无关，运维遗留）。

## 明确不归你（agent）做的

- 重启 core 宿主机、重建/重载 nginx、重打资源包、发布 Release → **Hermes**
- 安卓真机安装与点击 → **用户**
- 向上游提 PR → **没人做，禁止**

## B-28 整包回滚跨两个一致性边界（P1）

- **现象**：`/restore` 先在锁内写兼容镜像和回滚标记，释放锁后才调用 `save_players(force=True, replace_missing=True)`。中间崩溃会出现「标记/镜像已回滚、权威 manifest 未回滚」；玩家保存的设备记账、单玩家恢复标记也在玩家锁外。
- **根因**：整包镜像、manifest、meta 三份状态不在同一提交边界内。
- **要做**：把权威 manifest 提交、镜像重建、回滚信号纳入同一把锁/同一事务；或把回滚改成「先写不可变 revision 文档 + 一次 manifest 切换」。
- **判据**：在 manifest 提交前注入失败，`/load` 仍返回回滚前完整状态；在提交后失败，返回回滚后完整状态；不出现标记与内容不一致。
- **状态**：未做，依赖 B-26 的 revision 文档方案一起设计。

## B-26 多玩家提交不是崩溃一致的（P1）

- **现象**：`save_players()` 先覆盖固定路径的 `profiles/<id>.json`，最后才原子提交 `profiles.json`。若第二个玩家写入后进程崩溃，manifest 仍指向旧 revision，但文档内容已经变成新的；`/load` 会读到半提交结果。并发读也不在锁内，可能读到混合集合。
- **根因**：玩家文档路径不含 revision，manifest 的原子性只保护「引用集合」，不保护「被引用内容」。
- **要做**：玩家文档改为不可变 `<id>.<revision>.json`，manifest 条目记录文件名，提交后再清理未被引用的旧文件；迁移旧固定路径文档；`load_players()` 读锁内快照 manifest。
- **判据**：在写入第二份玩家后注入异常，`/load` 仍返回第一份完整旧提交；并发保存/读取不出现混合玩家集合。
- **状态**：未做，需单独一轮改动与故障注入测试。

## B-27 桌面端固定端口没有恢复入口（P1）

- **现象**：已持久化端口被长期占用时，启动游戏只会反复失败；没有「确认后重置 origin」的受控入口。
- **根因**：端口分配已改为绑定成功才持久化，但缺少用户可见的恢复流程。
- **要做**：设置页提供「重置本地/在线端口」，明确提示旧 origin 下的本机存档不会自动迁移，并保留旧端口记录；绝不静默换端口。
- **判据**：占用端口后进入明确失败态；重置后新端口生效且旧端口记录可查。

## B-29 CEF 的 debug.log 靠运行期裁剪兜底，未真正关闭（P2）

- **现象**：`webview_cef 0.6.2` 把 CEF 日志写在 exe 目录的 `debug.log`，没有上限；
  界面起不来、Chromium 后台反复报错时能写到 250 GB（2026-10-25 实机事故）。
- **已做**：`windows/runner/cef_log_limit.cc` 每 15 秒检查 exe 目录与工作目录的
  `debug.log`，超过 32 MB 就 `SetEndOfFile(0)`；CEF 句柄允许共享写，实机验证
  运行中裁剪成功、文件从 0 重新增长。断言在 `tool/check_update_manifest.dart`。
- **剩余**：根治是给 `webview_cef` 做受控 fork，在 `OnBeforeCommandLineProcessing`
  里加 `log-severity=disable`（插件固定了 `CefSettings`，Dart 层没有开关）。
  在完成 fork 前，裁剪是安全网而不是关闭日志。
- **判据**：Windows 实机连续运行 24 小时，`debug.log` 不超过 32 MB；界面异常循环下
  也不超过。需要 Windows 实机 + 重建后的 exe。

## 已关闭

`B-78 桌面端 vsync 源固定 adapter 0 / output 0，多屏与虚拟显示器下帧节奏对不上 → 已修（2026-10-29，P1，vendored webview_cef，hlh.36）→
现象：窗口在 1024×768 虚拟显示器（GameViewer / MuMu），而 adapter 0 的第 0 个输出是
NVIDIA 2560×1440@179；BeginFrame 按 179 Hz 发，实际显示 60 Hz，表现为「帧数够但看着不顺」，
最小化后也继续按刷新率空转。
根因：`webview_cef 0.6.2` 的 vsync 线程用 `EnumAdapters1(0)` + `EnumOutputs(0)` 等 vblank，
那不是窗口所在的那块屏。
修法：把包 vendor 到 `packages/webview_cef`（`dependency_overrides`），只改
`windows/webview_cef_plugin.cpp`：`PickVsyncWindow()` 选前台窗口，
`MonitorFromWindow()` 取 HMONITOR，遍历所有适配器/输出按
`DXGI_OUTPUT_DESC.Monitor` 精确匹配；换屏自动重取；找不到 output 时用该显示器自己的
`EnumDisplaySettings` 刷新率兜底；`IsIconic` 时跳过 BeginFrame。
断言：Windows 构建通过（hlh.36）；原生行为本机无自动断言，
关联 Dart 断言见 `check_local_server` 46 项、`check_desktop_channels` 69 项。
残余：需实机在多屏/串流/最小化三种情况下复核手感；升级上游时要重新打补丁（见
`packages/webview_cef/VENDORED.md`）。

`B-79 Windows 静态资源全部 no-store；CEF 对广告 iframe 也重装桥 → 已修（2026-10-29，P2，hlh.36）→
现象：资源包 2025.9 MB / 8252 文件，每次进游戏都从磁盘重读；`onLoadEnd` 对广告/统计
iframe 也执行全屏/键盘注入与 1.2 秒补焦，广告刷新时还会抢一次画布焦点。
根因：`LocalResourceServer._serve` 只给 HTML 设 `no-store`，其余资源没有任何缓存头；
`onLoadEnd` 不区分主文档与子 frame。
修法：带内容哈希的文件名（Cocos 产物常见）`public, max-age=31536000, immutable`；
其余 `no-cache` + ETag，命中返回 304；HTML 仍 `no-store`（每次请求都要重写注入内容）；
`onLoadEnd` 只认本地服务器 origin 的主文档。
断言：`check_local_server` 42→46（hashed immutable、no-cache+ETag、304 无 body、304 保留
ETag/Cache-Control）；`check_desktop_channels` 68→69（主文档过滤）。
残余：CEF 没设 `cache_path`，HTTP 缓存只在进程内有效；跨进程重启的收益要与 B-22 一起
在 vendor 里配持久 cache 目录，本轮不做。

`B-80 安卓切后台后 WebView 主循环继续跑 → 已修（2026-10-29，P2，Android，hlh.36）→
现象：`GameActivity.onPause` 只记录生命周期日志，没有暂停 WebView；切后台/暗屏后
JS 计时器与 rAF 继续跑，白耗电发热。
修法：`onPause` / `onResume` 成对调用 `webView.onPause()` / `webView.onResume()`。
断言：APK 构建通过（hlh.36）；无自动化断言。
残余：真机「切后台 → 回前台」复测，确认游戏能继续且不重载。

`B-00 Windows 本地 ZIP 导入不可用 → 自写 StreamingZip（`tool/check_desktop_zip.dart` 11 项 + `stress_real_pack`）`

`B-06 管理页 5 s 轮询没有 visibilitychange → 后台标签页停止轮询、切回立即补一次刷新
（`tools/test-cloud-saves.sh` 的 `管理页后台标签页暂停轮询`）`

`B-07 设备标识历史数据缺失 → 缺 device 字段显示「历史设备（未记录）」，不回填
（`tools/test-cloud-saves.sh` 的 `早期无 device 字段的存档显示为历史设备`）`

`B-09 .ps1 编码陷阱没有自动化 → tools/handoff.sh verify 增加「build-windows.ps1
为 UTF-8 BOM + CRLF」断言（`Windows 构建脚本编码` 一节）`

`B-16 存档 API 连接污染导致偶发 501（2026-10-25 新发现）→ do_POST 先鉴权后读体，
未授权请求的 body 残留在 keep-alive 连接里，被 http.server 当成下一个请求行
（`501 Unsupported method ('{"id":...}GET')`）；修复为先读完 body 再鉴权，超限时读完丢弃并
关闭连接。断言：`tools/test-cloud-saves.sh` 的 `未授权 POST 不污染 keep-alive 连接`；
注意该断言在服务端容器重新部署前会保持失败（源码已修，部署归 Hermes）。`

`B-17 check_desktop_zip 的 fixture 说明与实现不符（2026-10-25 新发现）→ 按文档「任意
带嵌套目录的 ZIP」生成的包会让套件在 `big.length()` 处抛 PathNotFoundException；
已把精确 fixture（3 条目 + 3 MiB assets/big.bin + 越界条目）写进 docs/06-testing.md。`

`B-03 SAF 目录授权（决策：不做，保留候选目录 + 手填）→
候选列表已经覆盖「应用外部目录 + 各外置卷的应用目录」，都是 WebView 能直接读的真实路径；
SAF 返回的 content:// 树无法作为 WebView 的资源根，要支持它必须把校验/导入/迁移三条路径
全部重写成 Storage Access Framework 抽象，收益（U 盘/厂商二级目录）不足以承担回归风险。
本轮只补了选择框里的说明文案（`storageAndroidCandidatesHint`），让用户知道为什么没有系统选择器。`

`B-04 令牌对游戏 JS 可见 → 设备令牌不再进入页面。
游戏页只注入 3 小时有效的存档会话令牌（scope 限定读写存档、不带管理员组），
原生心跳/在线代理改读 0600 的宿主专用文件（长期设备令牌）；吊销设备令牌会连带失效所有会话。
断言：test-cloud-saves.sh 的 8.6 一节（会话令牌可读写、不能签发/吊销、过期 401、连带失效）+
check_game_host_contract.dart 的会话令牌解析与文件名校验。`

`B-05 历史存档保留 1000 → 300（按你的要求实现）→
每个（用户 / 游戏版本 / 存档键）独立裁剪，永远从最旧的删起，同一秒的 ts-n 按序号排序；
history 目录本身就在 by-version/<gv> 下，所以 1.6.1 的清理动不到 1.6.2。
断言：test-save-versions.sh 第 8.5 节 8 条（300 份上限、边界、最旧优先、同秒序号、跨版本/跨键隔离、非历史文件不动）。`

`B-08 Windows 自更新 → 检查 / 下载 / sha256 校验 / 退出并自动替换全部打通。
替换由外部 PowerShell 脚本执行：等进程退出 → 解压到临时目录并校验 exe 存在 → 整目录备份 →
robocopy 覆盖 → 失败自动回滚并重启 → 清理。安装目录不可写时直接拒绝，不启动脚本。
断言：check_update_manifest.dart 22 条（清单解析、版本判定、文件名防穿越）+ 脚本 BOM/CRLF；
脚本在 Windows 构建机的沙盒目录实测：文件替换、旧文件保留、备份清理、退出码 0。`

`B-15 公开仓历史里含服务器域名 → 已清理（2026-10-25）→
用 git filter-branch 对全部 branches+tags 做 tree-filter，把 tool/check_cloud_saves.dart 里的
域名字面量替换为 <server>；本地备份 bundle 在 /tmp/opencode/pre-purge-*.bundle（41 MB）。
重写后 origin/feature/app-update 与 private/main 均以 --force-with-lease 强推，
重新 fetch 后 git grep 全历史 0 命中；本地 refs/original 已删、reflog 过期、gc --prune=now。
注意：GitHub 仍可能按旧 commit SHA 缓存对象，若要求彻底不可达需向 GitHub Support 申请 purge；
域名本身不是凭据（仍需 authentik + Bearer），当前达标线是「源码与可达历史均无字面量」。`

`B-18 管理页看不到按版本分区的存档 → 已关闭（hlh.20）→
`/list` 改为返回 `saves[]`（legacy + 每个 by-version），普通用户只返回本人；
`/history`、`/version`、`/raw` 允许本人读取，跨用户仍需管理员；管理页按
`gameVersion` 展示并传递历史/回滚/下载/删除参数。游戏内「存档」按钮对所有
用户挂载，打开同一套面板。
断言：test-cloud-saves.sh 7.9 节 3 条（自助列表、跨用户 403、本人历史 200）+
8.5 节 4 条（我的存档、data-gv、按钮全员挂载、无独立上传按钮）。`

`B-19 启动器存档页版本来源 → 已按新语义重做（本地验证通过，待部署）→
存档页默认跟随游玩形态，但**分区键必须分来源**：本地查看用已校验资源包的
currentGameVersion，在线查看用服务器清单版本；后者取不到时返回
online_version_unavailable，绝不借用本地版本。页面允许手动切换查看分区，
切换只影响查看，不改变运行中的游戏会话。缺本地资源时报
local_resource_missing，不查 legacy。
断言：tool/check_game_host_contract.dart 的「存档页按查看分区取版本」等 5 条。`

`B-24 多玩家云端存档按玩家拆分 → 已实现（本地验证通过，待部署）→
服务端 by-version/<gv>/profiles/<uuid>.json + profiles.json 原子 manifest，
游戏仍收发 PvZ2_PlayerProperties 数组；/load 注入 __pvz_profile_id，
/save 按 changedProfileIds/baseProfileVer 逐玩家合并，删除只认显式
deletedProfileIds；历史按玩家独立（/profile/history、/profile/restore）。
断言：test-save-versions.sh 第 11 节（玩家合并/删除/同名用户/UID/版本来源）+
test-sync-offline.js 第 17-18 节（逐玩家基准、显式删除、未接受不清队列）+
test-concurrency.py 12 客户端并发只接受一个写入。`

`B-25 普通用户不能回滚自己的存档 → 已修（本地验证通过，待部署）→
移除 /restore 前的全局 admin 门禁，改由各 handler 用 can_manage() 校验目标；
/profile/restore 同样本人可用。断言：test-save-versions.sh 第 11 节
「权限：普通用户能回滚自己的存档 / 不能回滚别人的存档」。`

`B-20 legacy 迁移的 migrated_from 为空 → 已修（本地验证通过，待部署）→
服务端 legacy 迁移返回 migrated_from="legacy"；sync.js 以 load_kind 为准，
空来源回退成 legacy 标签。
断言：test-save-versions.sh 第 9 节「legacy 继承来源显式标记为 legacy」+
test-sync-offline.js 第 16 节「迁移提示把空来源标成 legacy」。`

`B-21 正常同步把 gameVersion 塞进 data → 已修（本地验证通过，待部署）→
send() 把 gameVersion 放请求体顶层并从 data 剔除；服务端不再把 gameVersion
当成未知存档键跳过，存档写入 by-version/<gv>。
断言：test-sync-offline.js 第 16 节「gameVersion 在信封顶层而不是 data 里」+
test-save-versions.sh 第 9 节「回写后读到当前版本分区」。`

`B-30 手动上传后自动上传持续撞 stale_base → 已修（2026-10-26，Web E2E 验证）→
管理页「上传本机存档」成功后只更新云端 revision，没有推进同源游戏标签页的
`__pvzCloudProfiles` 基准；游戏下一次自动上传仍带旧基准，服务端判 stale_base，
用户看到「手动上传没问题、自动上传不及时」。修复：admin.html 上传成功后把
响应里的 profileVer/ver 合并进同源 localStorage（跨源 App iframe 不动，交回冲突面板）。
同时服务端对「内容未变」的玩家返回 profileUnchangedIds，客户端据此推进基准。
断言：node tools/test-admin-baseline.js 16 条；Web E2E：手动上传后游戏自动上传
777/666 成功、无 PROFILE CONFLICT。`

`B-31 纳秒版本号超过 JS 安全整数 → 已修（2026-10-26，服务端 126 项）→
非玩家键的 baseVer 是 time_ns（1.7e18），浏览器 JSON 解析成 double 再回传会
舍入到 256 ns 网格（...477579 → ...477600），精确整数比较永远 stale_base；
表现为设置等键第一次上传成功后，之后每次改动都传不上去。修复：
same_save_version() 用 double 相等判断同一版本，真实写入（微秒级以上）仍冲突。
断言：test-save-versions.sh「JS 舍入后的基准仍被认作同一版本 / 不产生假冲突 /
真正过期的基准仍然判冲突」。`

`B-32 Android 在线形态原生资源代理读不到存档桥 → 已随在线玩法删除关闭（2026-10-26）→
Dart 的 _jsStringLiteral 生成单引号 base:'...'/token:'...'，Kotlin 的
readBridgeCredentials 只匹配双引号，导致 online_resource_unavailable /
online_bridge_missing，游戏 WebView 直接吃 nginx 401。修复：正则同时接受
单/双引号；app/build.gradle 加 test 用 org.json 让 JVM 单测能覆盖原生 token 覆盖。
2026-10-26 在线游玩删除：OnlineGameResourceClient/OnlineSessionHeartbeat 与对应测试一并删除，本项关闭。`

`B-33 Android 本地资源包真机首屏/退出验证 → 待真机（2026-10-26）→
在线游玩删除后只保留本地资源包。此前模拟器首屏后 WebView 渲染进程
（sandboxed_process0）crashpad 崩溃、主线程等焦点超时被判 ANR，进程被系统杀掉
（swiftshader 软件渲染、3 GB guest；是 crashpad minidump，不是 OOM）。真机/
更大内存 + 硬件 GPU 必须用本地资源包复测，复测前不要把 Android 本地首屏
当成已验证能力。另：直接用
`flutter build apk --debug`（不带 --dart-define=PVZGE_SERVER）会让「登录」按钮
静默无反应，必须用 tools/build-apk.sh 或显式 dart-define；Play 页也应把
save_server_invalid 显示出来，避免用户以为按钮坏了。`

`B-34 Flutter debug 包每次启动记一条 Zone mismatch ERROR → 未处理（2026-10-26）→
main.dart 的 WidgetsFlutterBinding.ensureInitialized() 在 runZonedGuarded 之外，
debug 下 BindingBase.debugCheckZone 会报 "Zone mismatch" 并写进应用日志，
看起来像启动失败，干扰诊断。release 不触发。修法：把 binding 初始化、日志初始化
和 runApp 放进同一个 zone（注意 logger 初始化失败要降级）。优先级 P2。`

`B-35 已绑定账号的旧无 uid 设备令牌会 401 → 需产品决策（2026-10-26）→
akadmin 在 22:58 首次 Web 登录后目录绑定到 uid，5 个旧设备令牌没有 uid；
当前 ALLOW_LEGACY_NOUID=0，因此旧 APK 的云存档会 401，必须重新登录。
选择：等新 APK 发布后让用户重登（安全），或临时 ALLOW_LEGACY_NOUID=1
过渡（旧令牌可继续用，等于保留旧隔离强度）。不要为了省事长期开兼容开关。`

`B-36 多设备旧副本被登记为 unchanged → 下一次编辑静默覆盖云端 → 已修（2026-10-26）→
`save_players` 对「不在 changedProfileIds、但内容与云端不同」的玩家走 changed=False，
保留云端内容；`profileUnchangedIds` 修复又把这种旧副本也回报成 unchanged，客户端于是
把基准推进到云端 revision + 本机旧内容 hash。用户下一次编辑会带云端 revision 直接覆盖
另一台设备的进度（历史里还有，但用户看到的是静默丢档）。修复：只有 `prev_text == text2`
（逐字节一致）才进 `profileUnchangedIds`；被变更集跳过但内容不同的，客户端保留旧基准，
下一次编辑由服务端判 stale_base。断言：`tools/test-save-versions.sh` 的
「内容不同于云端的旧玩家不得回报 unchanged / 真正一致的仍然回报 / 旧副本不阻塞整包 /
旧副本上的下一次编辑必须冲突 / 云端仍是设备 1 的 12」5 条（121→126）；
`test-sync-live.js` 另加 1 条真实 sync.js 集成断言（旧副本之后编辑不覆盖设备 2 的 3）。
顺带修了同套件第 12 节测试隔离：`/save` 用 `zz-mp2-test`、清理却删 `zz-newmp-test`，
第二次跑会被上一次的 NewGuy 命中；现在两者统一为 `zz-newmp-test`。`

`B-37 oracle-sol 第二轮 P0/P1 → 已修（2026-10-26）→
1. **P0-1 单飞**：`sync.js` 旧上传失败晚到会把旧 payload 写回 pending，再用已推进的
   基准重发旧进度。修为 inflight 单飞 + 在途期间只落盘 + requeue 只保留更新值 +
   成功后才 pump；断言 `test-sync-offline.js` 的「在途时不再发第二个请求 / 失败晚到
   不覆盖更新的 pending / 重试发的是最新值 / 重试基准没有被失败请求推进」。
2. **P0-2 启动基准**：`/load` 后无条件写 CloudVer/ProfileBase，App 冲突后保留本机
   却带着云端 revision，下一次保存直接覆盖。修为只对 restore/identical/rollback 的
   键写基准，pending/conflict 保留旧基准；断言「冲突时保留旧的非玩家基准 / 玩家冲突
   时保留旧 profile 基准」。
3. **P0-3 管理页**：`adoptUploadedBaseline` 合并整个 profileVer，未发送的 B 也被推进，
   下一次删除 B 绕过删除冲突。修为只推进 `(profileSavedIds ∪ profileUnchangedIds) ∩
   本次发送`；断言「只推进发送且接受的玩家 / 未发送保持旧基准 / 冲突不推进」。
4. **P0-4 adopt 多标签页**：marker 被新标签页消费后旧标签页仍能用新基准上传。修为
   marker 记录 user 并校验、应用时推进 document generation、旧标签页写/上传/ACK 失效
   并 reload；断言「新标签页应用 / generation 推进 / 旧标签页写入被丢弃 / 跨账号快照
   被丢弃」。
5. **P1-5 删除 ACK**：A 的更新在途时删除 A，ACK 让基准被丢掉，删除永远不提交。修为
   保留 ACK revision/hash 供下一次 `deletedProfileIds`；断言「ACK 后仍带 deletedProfileIds /
   删除使用 ACK 后的新 revision」。
新基线：sync-offline 122→139、admin 11→16；服务端 426、总 684。`

`B-38 多标签页仍没有活跃写者租约 → 待办（P2）→
document generation 已覆盖「正常恢复云端 / 换账号 / adopt / 运行时用云端存档」
这些接管路径：接管后旧页的写入、pending 读改写、上传、ACK 全部失效并 reload。
但两个标签页**同时正常游玩**（没有接管事件）仍可能互相覆盖 localStorage/上传。
彻底方案是同 origin 写者租约（心跳 + 过期）或启动时检测到活跃租约就阻止进入
游戏。当前游戏页没有单写者门禁，先记录；不要在没解决前把「多开」当作受支持用法。`

`B-39 服务端/静态回滚必须成对 → 已写文档（2026-10-26，P1）→
旧整包写入器只更新兼容镜像，新服务端有 manifest 就优先读 profiles；回滚期间写进
镜像的进度会在重新升级后被忽略。发布回执记录匹配的服务端/静态版本；具体二选一
步骤见 docs/05-deployment.md 第 9 节。禁止在 manifest 存在时混跑旧写入器。`

`B-40 纳秒 revision 的 256 ns double 容差是兼容措施 → 长期改造（P2）→
same_save_version 按 double 分桶，不是严格 CAS；同一 double 桶内的两次真实写入
或时间戳重复仍可能误放行。长期应改成不透明字符串 revision（或服务端下发的
单调序号），客户端原样回传；只把 mtime 改成字符串不够，还要同步改掉当前
`isinstance(int)` 门禁和所有历史/回滚路径。`

`B-41 CEF debug.log 32 MB 是软上限 → 已知边界（P2）→
Windows 每 15 秒检查一次，峰值可能略超 32 MB；裁剪失败静默返回。250 GB 类无限
增长已被兜住，但不是严格配额。Android/iOS/OHOS 换段清理正常路径有界；OHOS 每次
写 open/close，无长句柄。真机/产物验证仍要在下一次 Windows 构建后做。`


`B-42 oracle-sol 第三轮 P0/P1 → 已修（2026-10-26）→
1. **P0 force 绕过单飞**：普通上传在途时 force 另开请求，晚到的失败会把旧 payload
   重排并用新基准覆盖 force 结果。修为 force 只登记意图，等当前请求结束后用最新
   本机内容发送；force 开始前的旧队列值在成功后被清掉，force 期间的新写入保留。
   断言 `[39]` 9 条。
2. **P0 迁移覆盖启动冲突**：migrated 循环无条件回写云端旧内容。修为只回写
   `loadConfirmed` 的键，pending/冲突/保留本机全部跳过。
3. **P0 换号丢弃目标账号 pending**：`switchUser()` 后误把 `bootPendingEarly` 清空。
   修为重读目标账号队列；断言换号后目标账号离线进度不被云端覆盖。
4. **P0 单玩家回滚后旧 pending 复活**：`adoptRestoredProfiles()` 更新持久队列后
   `bootPendingEarly` 仍是旧快照，后续回滚写回旧内容。修为回滚处理后重读 pending。
5. **P0 generation 不完整**：普通恢复不推进 generation、flush 检查与落盘不原子、
   换号/运行时用云端未接管。修为所有接管入口推进 generation；meta/基准/pending
   统一走 `guardedWrite`（写前检查 + 写后复检回滚）；/load 与启动关键节点发现
   已被接管就 reload；断言 `[36][37][40][41]` 10 条。
6. **P1 pump 不排空持久队列**：在途期间 flush 已落盘并清空内存，ACK 后 pump 只看
   内存直接返回。修为内存为空时走 `drainPending()`；断言 `[42]` 4 条。
7. **P1 删除 ACK 只覆盖 saved**：unchanged 确认后删除、首次 ACK 前删除新玩家都会
   漏删/假冲突。修为统一 saved ∪ unchanged ∪ 已发送 ID 的接受判定；断言 `[43][44]` 4 条。
8. **P1 管理页老服务端 fallback**：无逐玩家 arrays 时把「发过」当「确认」。修为
   要求 `saved` 明确包含玩家键；整包 `ver` 也只推进 saved 的键；断言 admin 19 条。
新基线：sync-offline 139→163、admin 16→19；服务端 453、总 711。
残余：B-38 的活跃写者租约仍是 P2，两个标签页同时正常游玩不在支持范围。


`B-43 oracle-sol 第四轮 P0 → 已修（2026-10-26）→
1. **P0-1 pending 写后补偿复活旧值**：`guardedWrite` 的写后恢复 `prev` 会把旧
   generation 的值写回共享队列，新页可能在补偿前读走。修为 pending 按 generation
   分槽（`__pvzPending:<gen>`），新写者只读自己的槽；接管时按需携带/清空并删除旧
   槽；基础键 `__pvzPending` 只在首次升级时迁移一次，之后用
   `__pvzPendingLegacyFor` 标记拒绝旧页晚写。断言 `[45]` 6 条。
2. **P0-2 恢复先暴露基准 / 单玩家回滚未接管**：恢复键的 `CloudVer`/`ProfileBase`
   提交移到实际恢复之后；单玩家回滚在任何游戏键/基准变更前
   `takeOverDocument('profile rollback')`；send/force 在 generation 检查后立刻
   快照基准，构造信封后再检查一次。断言 `[46][47]` 6 条。
3. **P0-3 force 期间新写入等于旧队列值被误删**：删除按 `forcePrevPending` 内容
   相等推断年代的逻辑。force 开始时把本次发送快照持久化，ACK 只清理仍等于发送
   快照的值；期间游戏重新写入的值（哪怕与旧队列相同）会覆盖快照并被补传。
   断言 `[48]` 5 条。
新基线：sync-offline 163→185、admin 19；服务端 475、总 733。
残余仍是 B-38（活跃写者租约）与 B-40（纳秒 CAS 容差）。

`B-44 手工复核第五轮（oracle-sol 前自查）→ 已修（2026-10-26）→
1. **换号写入边界**：`/save` 增加 `expectedUid`（页面 `/load` 确认的 uid）；
   session 运行中被换掉时服务端 403 `identity changed`，客户端保队列、发
   `pvz-save-identity-changed`、停止后续上传等待刷新。管理页手动上传先比对
   `__pvzSyncUser`，并把 uid 随请求发送，避免把 A 的本机档写进 B。断言：
   sync-offline `[58]` 5 条、save-versions「换号保护」4 条。
2. **force 200 不可解析**：旧代码把 HTTP 200 的 HTML/代理错误当「全部接受」，
   清队列并报成功。修为按普通 send 的同一判据，保留 pending、发失败事件。
   断言：sync-offline `[56]` 3 条。
3. **版本不匹配首传**：云端只有更高版本时，启动的 firstUpload 会把本机碰巧
   存在的旧档塞进 pending，升级后被重放。修为 `syncVersionMismatch` 时跳过
   firstUpload。断言：sync-offline `[57]` 3 条。
4. **整包回滚身份**：兼容镜像重建时保留 `__pvz_profile_id`；`/restore` 传
   `allow_restore`，旧快照没有 ID 时按位置/唯一名字从 tombstone 找回；
   被删玩家恢复原 ID，不再新建 UUID。管理员代回滚时 `ownerUid/ownerUsername`
   仍归属目标目录，不写成管理员。断言：save-versions「整包回滚」2 条、
   「跨用户回滚」3 条。
5. **单玩家回滚回插**：本机已删除的玩家被管理员从历史恢复后，旧逻辑只在
   local/pending 中替换已存在的条目，不会重新插回；下一次上传仍带
   `deletedProfileIds` 把回滚删掉。修为按云端位置插回数组与 pending，并更新
   该玩家的基准。断言：sync-offline `[61]` 4 条。
6. **删除重置回滚标记**：删除玩家键后旧 `restoredAt/restoreSource` 仍留在
   `.meta`，新档第一次 `/load` 会被客户端当成被回滚过。修为删除键时清掉这两个
   字段。断言：save-versions「删除玩家键后旧回滚标记」2 条。
7. **原生写入竞态**：`backfillProfileIds`、单玩家回滚、运行时「用云端」原先用
   原始 setItem 直接写共享键，写前检查与写入之间被接管时会留下旧数组。修为
   新增 `guardedRawWrite`（写前检查 + 写后复检回滚）；adopt 竞争失败时保留
   marker 给下一次启动，不替用户丢掉选择。断言：sync-offline `[59][60]` 5 条。
新基线：sync-offline 197→225、save-versions 126→137；服务端 526、总 784。
残余：B-38（活跃写者租约）、B-40（纳秒 CAS 容差）、B-45（本轮 server.py 待重启）、
B-46（pending carry 配额满时留在旧槽）。`

`B-45 本轮 server.py 改动待容器重启 → 已关闭（2026-10-26 09:25）→
2026-10-26 09:25 CST 已 `docker restart pvzge-save` 加载源码
`8105df2a…`（118128 B）。重启后验证：`/healthz` ok；临时用户
`expectedUid` 不一致 → 403 `identity changed`，一致 → 200 且写入、
`PvZ2_Settings` 的 `device` 元数据为 `verify-dev`；临时目录已删除；
真实 `akadmin` `/load?gameVersion=0.16.1` 返回 1 个玩家（NBMAN）、4 个键，
`PvZ2_PlayerProperties.json`/`profiles.json` mtime 仍是 10-25 22:58（未被读操作改写）；
`test-cloud-saves.sh` 重启后 111/0/0。回滚备份：`/tmp/opencode/server.py.before-review2`
（112544 B，第五轮前源码）；若需回滚，复制回 `save-api/server.py` 再 restart。
注意：B-51 的 `/restore` 标记顺序问题仍在。`

`B-46 pending carry 配额满时留在旧 generation 槽 → 已知边界（P2）→
接管时新槽写入失败会保留旧槽（数据还在 localStorage，但新写者只读自己的槽），
本页后续恢复会用云端覆盖游戏键，旧槽里的未上传改动只能靠人工排查。配额满/
隐私模式本身已经让 localStorage 无法可靠持久化；不为此引入跨槽扫描，避免
旧页晚写复活（B-43 的教训）。判据：正常配额下 `[45]` 全过；配额异常的恢复
路径需要浏览器手工验证。`

`B-47 旧页面不识别 generation → 已知边界（P2）→
部署前已打开的旧 sync.js 页面没有 `__pvzSyncGeneration` 逻辑，仍可能写基础键
`__pvzPending` 或旧游戏键。新页面首次接管会迁移一次基础键并用 per-generation
marker 拒绝之后的基础键晚写；但旧页面自身不会 reload。发布后提示用户刷新/
重开游戏页；不要在多开旧页时把「多标签页」当作受支持用法。`

`B-48 手工复核第六轮（oracle-sol 前自查）→ 已修（2026-10-26）→
1. **换号归档写失败会丢存档**：`switchUser` 原来先把游戏键写进 `__pvzUserSave_*`
   再无条件清本机键；localStorage 配额满/隐私模式下 setItem 静默失败，本机
   唯一存档就被删了。修为先归档并逐键读回校验，全部成功才清；失败时中止换号、
   本页放弃云同步、保留旧账号存档并提示刷新。恢复目标账号归档同样只有落地
   成功才删归档。断言：sync-offline `[62]` 6 条。
2. **generation 写失败无限 reload**：`takeOverDocument` 写 `__pvzSyncGeneration`
   失败时仍推进内存 generation，`writerStale()` 恒真，恢复/基准发布路径反复
   reload 到进不了游戏。修为写后读回校验，失败不推进、降级为旧行为继续启动。
   断言：sync-offline `[64]` 3 条。
3. **回填 profileId 的张冠李戴**：`resp.profiles` 含「云端有、本次没发」的玩家，
   index 是提交后的位置；请求在途期间新建的同名玩家会拿到别人的 ID，下一次
   保存就覆盖那份云端进度。修为只回填本次发送数组内同位置、且内容哈希仍是
   发送内容的条目。断言：sync-offline `[63]` 3 条。
4. **跨版本 pending 覆盖新版本**：pending 不分版本，升级后旧版本离线改动会被
   当成「本机更新」上传到新版本 exact 分区。修为启动时若上次同步版本不同且
   云端当前版本已有该键（exact），丢弃该键的旧 pending，转入正常冲突/恢复；
   只有 migrated/none 才允许升级搬运。断言：sync-offline `[65]` 6 条。
5. **冲突页跨账号写入**：冲突页「保留此设备」是独立页面的直接 `/save`，换号后
   会把上一个账号的本机存档写进新账号。修为上传前重新 `/load` 复核账号、
   用最新 `ver` 做基准、带 `expectedUid`、响应身份不一致即停止；同时给冲突页
   摘要加转义。断言：cloud-saves 3 条静态检查 + 服务端既有 expectedUid 用例。
6. **玩家键设备元数据覆盖回滚标记**：`/save` 的玩家分支在 profile 锁外
   `record_device` 整文件读改写，会和 `/profile/restore`、`/restore` 写
   `restoredAt` 交错，把回滚标记覆盖掉。修为设备元数据移入 `save_players`
   的 profile 锁内，且只记真正写入了玩家文档的请求。断言：save-versions
   「设备元数据」5 条。
新基线：sync-offline 225→243、save-versions 137→142、cloud-saves 108→111；
服务端 552、总 810。`

`B-49 冲突页「保留此设备」无法表达删除 → 已知边界（P2）→
冲突页上传整包数组，但不带 `deletedProfileIds`（它没有逐玩家基准）。用户在
本机删掉某个玩家后走冲突页「保留此设备」，服务端按「数组缺项不等于删除」
保留该玩家，冲突页会把旧玩家带回来。显式删除仍走管理页/游戏内面板的删除
接口；要让冲突页也表达删除，需要把本机 `__pvzCloudProfiles` 的 hash/rev 带进
请求，风险高于收益，暂不做。`

`B-50 管理页手动上传新建玩家不推进该玩家基准 → 已知边界（P2）→
手动上传的 `submittedProfileIds` 只包含本机数组里已有 `__pvz_profile_id` 的
玩家；本机新建、服务端刚分配 ID 的玩家不在里面，管理页不推进它的基准。
游戏页下一次自动保存会按位置/名字匹配并回填，通常无感；若用户在自动保存前
就把该玩家删掉，云端副本因缺 hash 不会被 `deletedProfileIds` 删除，下次
`/load` 会带回来。彻底修需要管理页也回填 ID/hash（与游戏页共享基准），
留待后续。`

`B-51 /restore 玩家键的镜像/标记先于 manifest 提交 → 已知边界（P2）→
整包回滚先 atomic_write 兼容镜像并写 restoredAt，再调用 save_players 提交
manifest；两步不在同一个锁内，进程在中间崩溃会留下「标记说回滚了、manifest
还是旧内容」的状态。历史文件本身总是合法数组，实际触发概率极低；若后续改
/restore，应把标记写进 save_players 的锁内、在 manifest 提交后原子落盘。`

`B-52 adopt 快照会清空整条 pending → 已知边界（P2）→
applyAdoptedCloud 接管时 carry=false，跳过快照里没有的键。那些键若云端也没有，
本机内容仍在，后续 firstUpload 会补传；若云端有而快照没有（正常 /load 不会
出现），本机旧内容会走下一次冲突/恢复判定。不是静默丢档，但队列语义不够
精细；暂不为多键快照引入逐键 carry。`

`B-53 多标签页没有真正的跨上下文串行化 → 已关闭（2026-10-26，P1，单标签页门闩）→
oracle-sol 最终复核第 4 条：`guardedRawWrite` 的写后补偿不构成 CAS。写入前
检查 generation 只能缩小窗口；「检查通过 → 新标签页接管 → 旧值落盘」仍然
存在，写后读回也无法区分赢家写入同值（ABA）。本轮已把补偿从「写回 prev」
改为「只有当前值仍是本次写入时才删除，并写 `__pvzResync` 指纹；下一次启动
按云端重建，pending 内容不同则保留重放」，避免补偿本身二次覆盖赢家；但
这不是互斥，两个标签页同时正常游玩仍可能产生最后一次写入者获胜。
彻底修需要 Web Locks/服务端租约/generation 隔离的不可变提交，并把游戏的
setItem hook 纳入同一边界；代价是启动必须异步门控或限制「同一账号只允许
一个活动标签页」。当前产品按单标签页使用，暂不做；真要做另开任务。
断言：sync-offline `[59]`、`[71]`（赢家新值不被删/不误标）、`[72]`（resync
云端重建）。

**2026-10-26 第八轮复核结论（仍为唯一剩余 P1）**：`guardedRawWrite` 的写后
删除 + resync 只是收敛，不是互斥。可行的最小完整方案是「宿主级生命周期锁」：
Web 端用 `navigator.locks` 在**游戏文档之外**持锁（例如入口页持锁后再加载
游戏 iframe，或由入口页 document.write 游戏 HTML），拿不到锁的第二页只显示
「已在另一个标签页游玩」；App/Android 已有 `GameActivity.running` 单实例
门禁，Windows 需再确认多进程共用 user-data 目录。Web Locks 是异步 API，
不能在当前同步注入的 `sync.js` 里「先拿锁再让游戏启动」；因此不能在现有
单文档架构里打补丁解决。未完成前不得宣称支持多标签页。

**2026-10-26 第九轮落地（后被第十轮修正）**：产品决定接受「Web 同一浏览器
只开一个游戏标签页」，并在 `sync.js` 末尾用 `navigator.locks` 获取
`pvzge-game-writer` 生命周期锁。后来者拿不到锁就 `window.stop()` + 覆盖提示；
锁回调前的游戏键写入进内存缓冲，grant 后经上传 hook 落盘，blocked 后丢弃。
断言：sync-offline `[80]-[85]`。
**第十轮修正**：oracle-sol 复核指出锁拿得太晚——第二个标签页在拿锁前已经跑完
`/load`、恢复与 generation 推进，正在游玩的标签页未上传改动会被判废。现在
Web 顶层只请求锁，拒绝就不 boot；grant 后才创建同源 iframe，游戏在子 frame
执行 boot，父页持锁到卸载。写入门闩对 pending 的所有键做影子缓冲，blocked 后
ACK/失败回调/重试/基准/游戏键全部拒绝；运行期采用云端失败会回滚已写键/meta/
玩家基准，回滚失败则停止本局写档。断言 sync-offline `[80]-[88]`，Web/App 各
**408/0**。多标签页**正常游玩**不再受支持，也不再是 P1。`

`B-54 版本保护旧无账号备份键不迁移 + _anon 段 → 已知边界（2026-10-26，P2）→
`local_save_guard.dart` 把备份键改成 `账号+版本` 后，升级前留下的
`__pvzBlocked_<ver>_*` / `__pvzState_<ver>_*` 不再被读取，也不会被删除。
不能迁移：旧键没有账号信息，猜归属会把 Alice 的备份恢复给 Bob。代价是
旧安装的降级备份不可达（活动键本身不受影响），并且 `__pvzSyncUser` 为空时
落到 `_anon` 段，与字面用户名 `_anon` 不可区分。需要单独的一次性迁移/
清理动作，不能在 guard 里猜。`

`B-55 tombstone 无上限增长 → 已接受（2026-10-26，P2）→
`profiles.json` 的 `deleted` 不再截断 100 条：删除身份是安全边界，按容量
裁剪会让第 101 次删除后的旧设备把已删玩家当新玩家重建。条目很小（id/name/
index/time），普通用户不会产生成千上万条；未来要清理需要独立的过期协议 +
客户端最低版本门槛，不能再用「保留最近 N 条」。`

`B-56 restoredProfileEvents 只保留最近 20 条 → 已接受（2026-10-26，P2）→
连续单玩家回滚超过 20 个不同玩家时，更早的事件会被裁掉；离线设备可能漏掉
最早的几次回滚通知。保留 20 条是为了让 meta 不无限增长；实际单账号玩家数
远小于 20，且漏掉的事件仍会因为 revision 变化在下一次保存时撞 stale_base，
不会静默覆盖。`

`B-57 oracle-sol 复核三项 P2 → 已关闭（2026-10-26）→
1. 连续回滚 A/B 只保留最后一个、同秒 at 去重：`/profile/restore` 在锁内追加
   毫秒级严格递增的 `restoredProfileEvents`，`/load` 输出全部未读事件并按
   profileId 取最新；断言：save-versions「回滚事件」12 条。
2. tombstone 超过 100 条旧 ID 复活：取消 100 条截断；断言：save-versions
   「tombstone：创建 101 个玩家 / 一次删除 101 个 / 第 101 次删除后最早的 ID
   仍不能复活」5 条。
3. 空档保护弹窗未转义玩家名/关卡：`sync.js` 的 `fmt()` 统一 `esc()`；
   断言：sync-offline `[67]`「空档提示框转义玩家名（防 XSS）」。
`

`B-58 账号归档加版本段后旧无版本账号归档不可达 → 已知边界（2026-10-26，P2）→
第八轮把 `userSaveKey/userStateKey` 改成 `<user>_<gameVersion>_<key>`，防止
低版本恢复高版本账号内容。升级前留下的 `__pvzUserSave_<user>_<key>` /
`__pvzUserState_<user>_<key>` 没有版本信息，无法安全判断能否交给当前版本，
因此不读取也不删除。代价：升级后第一次换回旧账号时，目标账号的**未上传**
本机归档不会被恢复（云端 `/load` 仍会恢复已同步内容）。需要独立的带版本
迁移/清理动作，不能在读取路径猜版本。`

`B-59 采用云端失败后旧 pending 槽成为孤儿 → 已知边界（2026-10-26，P2）→
`takeOverDocument('adopt', false)` 会推进 generation 并把旧队列留在旧槽，
只有采用全部成功后才由 `dropPendingGen` 删除。若写游戏键失败，旧槽保留
（正确：唯一副本）；但下一次启动只读新 generation 槽，旧槽不可达，直到某次
采用成功也只删「上一次」的槽，最初的旧槽会永久残留。内容不会丢/串档，只是
占配额。彻底修需要记录「被放弃的 generation」列表并在采用成功时统一清理，
或把旧队列搬到新槽并加「待放弃」标记。`

`B-60 管理页两个共享基准非原子 → 已知边界（2026-10-26，P2）→
`adoptUploadedBaseline` 分别写 `__pvzCloudProfiles` 与 `__pvzCloudVer`，
localStorage 没有事务。P2-1 已把身份复核放在函数开头和每次落盘前，但两次
`setItem` 之间若恰好换号，仍可能留下「Profiles 已更新、Ver 未更新」的半状态
（下一次上传会撞 stale_base/冲突，不会静默覆盖）。彻底修需要合并成单键或
引入基准 generation 字段。`

`B-61 guard 合并归档 pending 失败后队列搁浅 → 已知边界（2026-10-26，P2）→
进入新版本时 `mergeArchivedPending(CUR)` 若写失败，活动 pending 已被
`archivePending(before)` 移走，而版本上下文仍会推进；同版本启动不会再合并，
队列停在归档键里，直到下一次版本切换。内容没丢，但不会自动重放。可在
「同版本」分支按 `__pvzPendingMergeFailed` 标记重试合并；本轮未做，避免在
归档失败路径上再增加写入状态。`

`B-62 恢复/采用云端回滚使用裸 setItem → 已知边界（2026-10-26，P2）→
第八轮在恢复/采用云端部分写失败时把已落地键回滚到原值。回滚循环用裸
`localStorage.setItem/removeItem`（不走 `guardedWrite`），只在循环前检查一次
`writerStale()`；回滚途中若另一个标签页接管，可能把赢家刚写的值盖回一个小
窗口，随后本页 reload 收敛。改成 `guardedRawWrite` 会在回滚时触发 resync
标记（可能把回滚值当成过期写入），本轮选择保留现状并记录。`

`B-63 旧 __sync_native_token 明文文件只在启动/登出清理 → 已知边界（2026-10-26，P2）→
在线游玩删除后原生代理不再需要 0600 的 `__sync_native_token`；启动/登出会删除这个
遗留文件。若用户升级后从未启动新版（或旧版进程一直不退出），文件可能继续留在
应用目录。内容只是设备令牌，不是新暴露面；需要的话可在安装/首次升级时主动清理。`

`B-64 Web 入口 iframe 的真实游戏首屏仍需线上复测 → 已关闭（2026-10-26，P0，现场黑屏）→
第十轮的「顶层 window.stop() + 同源 iframe」在真实浏览器里就是线上黑屏。根因：父文档在
</head> 就被 stop，document.body 从未生成，整棵文档树 requestAnimationFrame 一次都不触发
（真实 Chromium 实测 2 秒 0 次回调）；iframe 里 cocos 资源全部 200 加载完，但
cc.game.isPaused()===true、director.getTotalFrames()===0、getScene()===null。
对照同一份 index.html + 同一份注入脚本在顶层文档直接跑是 frames=412 / mainScene；
线上 14:43 访问日志同样显示游戏资源全部 200 后没有任何后续请求。
改法：删除 iframe 宿主（writerHostChild/startWriterHost/mountWriterHostFrame/
blockWriterHost/writerHostOverlay/hideWriterHostOverlay 及对应分支），改为写者资格传递
（pass）：公网 Web 无 pass 的顶层只做一次极短交接（ifAvailable 拿 pvzge-game-writer →
sessionStorage 写一次性 pass → window.stop() → location.replace(location.href)，锁持有
到卸载）；带 pass 的顶层消费 pass 后走原来的顶层 boot（与 App/桌面同一条路径）。锁被占时
只渲染全屏提示、绝不 stop（stop 后提示层同样画不出来），并提前吞掉 4 个存档键的
setItem/removeItem；pass 页在 armWriterGate 拿不到锁时 250ms×8 重试躲开卸载竞态。
断言：test-sync-offline [80]/[83]/[86]/[95]（Web 441→473，App 475）。
真实浏览器验证（非 localhost 域名 + 非单实例宿主）：iframes=0、frames=463、
scene=mainScene、writerLock=granted；第二标签页提示层 1100×673 可见、不 boot、
存档键写入被吞。残余：真实账号完整一局（音频/全屏/触控/退出/云上传）仍需人工；
公网 Web 首次进入多一次导航（交接页），旧标签页必须硬刷新。
`B-77 桌面端快捷键：页面已经收到 keydown，游戏却不响应（event.code 为空）→ 已修（2026-10-28，P0，注入脚本，hlh.35）→
现象：hlh.33/34 实机日志里 `key=1 code="" keyCode=49 target=CANVAS#GameCanvas`
已经到达页面，但游戏选卡/铲子没反应；hlh.34 的校正只对 Meta 这类还原不出
code 的键生效。
根因（两层）：
  1. `webview_cef` 的 `getCefKeyEvent` 把整条 Windows `lParam` 塞进
     `CefKeyEvent.native_key_code`（正确值是扫描码 `(lParam >> 16) & 0xFF`），
     Chromium 据此算出的 `event.code` 是空字符串；
  2. 游戏（Cocos）的键盘监听绑在 `#GameCanvas` 上，热键映射用 `event.code`
     （`Iw[code]` → KeyCode 枚举），`code` 为空就映射成 NONE，游戏直接忽略。
为什么 hlh.34 没修好：校正判断用了「还原后」的 code（Digit1，非空），
`wrongCode` 恒 false；只有 keyCode 91（Meta）这类还原不出的键才触发。
修法：判断**原始** `event.code` 是否缺失；用 keyCode 还原 `Digit1/KeyA/...`
后，在 window 捕获阶段 `stopImmediatePropagation` + `preventDefault`，把带
正确 code 的 `KeyboardEvent` 重派发到 `#GameCanvas`（bubbles=true）。原生
事件被截住，不会双份 keydown；真实输入框（玩家名/聊天）不拦；F10/F11 由
宿主处理，不经过这层。
断言：新增 `tool/check_keyboard_script.mjs` **10 项**（body 时序 3 + 校正 7），
`check_desktop_channels` 65 → **68**（补注入重试、校正契约、原始键日志）。
基线 1295 → **1305**（服务端 828 + 客户端 477）。
残余：根子在 `webview_cef` 的 `native_key_code`；页面校正只是兼容层。上游
修复后这层会在 `code` 非空时自动早退，不需要删。更彻底的做法是 vendor 插件
并改 `windows/webview_cef_keyevent.h`，代价是维护一份三方包，暂不做。

`B-76 桌面端游戏内快捷键在 hlh.31 再次失效（数字/字母键全丢）→ 已修（2026-10-28，P0，注入脚本 + Dart，hlh.32）→
现象：用户更新到 hlh.31 后，游戏里的数字选卡、字母铲子、F 键全部失效，鼠标正常。
hlh.30 的同一条键盘修复代码仍在，且 hlh.31 没有改动键盘路径。
根因：`desktopKeyboardScript` 一进来先写 `window.__gardendlessKeyboardReady`
标志、再检查 `document.body`。`controller.initialize()` 返回得比页面加载快，
注入可能落在 HTML 解析中：隐藏探针被解析器移走/重建、焦点丢失；loadEnd 的
第二次注入看到标志直接 return，CEF 的 `current_focused_browser_` 再也没被赋值，
`sendKeyEvent` 第一行就丢键。时序竞争，所以同一份代码会「hlh.30 能用、
hlh.31 失效」。
修法：只有探针真正挂到 DOM 并聚焦成功才算安装完成；body 未就绪时等
`DOMContentLoaded` 并低频重试（不再提前写标志）；每次注入在没聚焦成功时补焦；
`setClientFocus(true)` 提前到聚焦探针之前；loadEnd 1.2s 后再注入并强制
blur+focus 一次（`__gardendlessKeyboardNudge`），覆盖「浏览器还没拿到客户端
焦点、focusednode 没上报」的情况。真实输入框有焦点时绝不抢。
诊断：新增 `keyboard.log`（应用支持目录），每次进游戏最多 6 行：安装状态 +
前 5 个 keydown（含 activeElement），下次复发能区分「按键没进页面」还是
「页面收到了但游戏没处理」。
断言：`check_desktop_channels` 61 → **65**；`check_fullscreen_script` 的假 DOM
补上 `window.close`（hlh.31 的退出接管会 bind 它，属测试环境保真度修复）。
残余：时序修复是必要的，但不是全部——hlh.33 实机日志证明按键已经到达页面，
游戏仍不响应，另见 B-77（`event.code` 为空 + Cocos 按 code 映射）。

`B-75 点游戏内「退出」后整个窗口未响应（卡死）→ 已修（2026-10-28，P0，注入脚本 + Dart，hlh.31）→
现象：Windows 桌面端进入游戏后点游戏主菜单的「退出」，加载器窗口直接变成
「未响应」，只能强杀。
根因：游戏把退出实现成 `window.close()`（资源包 `tmppatch.js` 里
`electronAPI.quit = () => window.close()`）。CEF 是**离屏浏览器**，没有
「脚本打开的窗口」这层语义；`window.close()` 会把浏览器对象销毁，而
`webview_cef` 的 `OnBeforeClose` 是空实现（`common/webview_handler.cc:164`），
Flutter 侧还在用这个浏览器 id 的纹理与输入通道 → 主线程卡死。
修法：注入脚本覆写 `window.close`，通过 `window.gardendlessDesktop` 发
`window:closeGame` 回宿主；Dart 侧走和加载器「返回」按钮**同一条**收尾路径
（停本地服务器、注销会话、pop 回首页），根本不销毁 CEF 浏览器。桥不在时
（普通浏览器）保留原生 `window.close`。退出流程加 `_closing` 重入保护。
断言：`check_desktop_channels` 60 → **61**（window.close 被接管 +
`window:closeGame` 接线 + 重入保护）。
残余：如果页面在注入脚本安装之前就调 `window.close`（理论上只在加载早期），
仍会走原生 close；当前游戏不会这样。

`B-74 桌面端游戏内键盘完全失效（快捷键、F11、文字输入都不行）→ 已修（2026-10-28，P0，Windows runner + 注入脚本，hlh.30）→
用户报告：桌面端「选择植物/铲子的快捷键」失效、F11 也不全屏；**同一份游戏在 Edge 里正常**。
两个独立根因，缺一不可：
1. **输入法把键码换成了 `VK_PROCESSKEY`**。中文输入法激活时，WM_KEYDOWN 的
   `wParam` 会被替换成 `0xE5`，真正的键码要用 `ImmGetVirtualKey` 取回。
   `main.cpp` 原来把 `wParam` 原样转给 `handleWndProcForCEF`，页面收到的键码
   全是 `0xE5`（数字键偶尔正常、字母/F 键全丢），宿主的 F11 判断也永远不匹配。
   修法：`ResolveVirtualKey()` 还原真键码，只用于「F11 判断」与「转发给 CEF」；
   原消息不动，继续交给 `TranslateMessage`/`DispatchMessage`，输入法组字不受影响。
   runner 增加链接 `imm32.lib`。
2. **CEF 的键盘事件没有投递对象**。`webview_cef` 的 `WebviewHandler::sendKeyEvent`
   只发给 `current_focused_browser_`，该成员只在渲染进程上报
   `FocusedNodeChanged` IPC 时赋值（`common/webview_handler.cc:66`，全仓唯一赋值点）。
   游戏 Canvas 不是可聚焦元素、页面加载后也没有焦点变化 → 该成员恒为 null，
   `sendKeyEvent` 第一行就 return。实机插件日志：事件确实发出、`focused=0`，
   页面零 keydown。
   修法：`desktop_keyboard_script.dart` 在页面加载后聚焦一个**隐藏的可聚焦
   输入框**（屏幕外、透明、不吃指针事件、实时清空），强制触发一次焦点节点变化；
   同时 Dart 侧显式 `setClientFocus(true)`（Flutter 的 Focus 节点拿不到焦点，
   插件的 `Focus.onFocusChange` 不会自己调）。实测之后页面能收到
   真正的 keydown（`activeElement === CANVAS`），原生输入法也能用。
   为什么不用合成事件兜底：试过「runner → Dart → `executeJavaScript` 派发
   KeyboardEvent」，能出键但会和原生通路**双投递**（一次按键两个 keydown），
   而且丢掉输入法；原生通路修好后已删除那段代码。
证据链（2026-10-28 实机，诊断构建）：
- 修复前：消息循环日志 `msg=0x0100 class=FLUTTERVIEW vk=0xE5`（字母/F11），
  页面零 keydown；
- 修复后：`vk=0x31/0x41/0x58/0x73/0x7A` 真实键码，页面 keydown
  （`key:"a" keyCode:65 active:CANVAS`），F11 窗口样式
  0x14CF0000 ↔ 0x96000000。
顺带：游戏页顶部工具条改成 **F10 显隐**（原来鼠标划过顶部就弹出，会挡住游戏
顶部卡片，用户明确要求去掉）。F10 是游戏 `KeyListener` 里的空分支，不冲突。
断言：`check_desktop_channels` 55 → **60**（F11 消息级拦截、按下/抬起都吞、
VK_PROCESSKEY 还原、还原值同时用于判断与转发、F10 转发链路、工具条不再悬停、
键盘引导脚本接线）。

`B-73 桌面端 F11 完全无效 → 已修（2026-10-28，P1，Windows runner + 诊断开关）→
现象：Windows 桌面端按 F11 没有任何反应；游戏内「设置 → 全屏」也不生效（有同一根因的一半）。
根因：**我们拦错了窗口**。hlh.28 把 F11 处理写在 `FlutterWindow::MessageHandler`
（顶层窗口 `FLUTTER_RUNNER_WIN32_WINDOW` 的 WndProc），但真实键盘消息由 Windows
投递给**有焦点的子窗口** `FLUTTERVIEW`（Flutter 的 view），子窗口消息根本不走顶层
WndProc。桌面实测证据（2026-10-28，Windows 实机）：
- `PostMessage(FLUTTERVIEW, WM_KEYDOWN, VK_F11)` → 窗口样式 0x14CF0000 不变；
- 同一条消息 `PostMessage(顶层, ...)` → 0x96000000（全屏生效）。
所以之前只有测试脚本直投顶层时「能用」，真键盘永远到不了处理器。
修法：在 `main.cpp` 的消息循环里、`TranslateMessage`/`DispatchMessage` **之前**调
`FlutterWindow::HandleKeyMessage(msg)`；命中 F11 时 `continue`，同时**跳过**
`handleWndProcForCEF`（否则页面也会收到 F11，和宿主抢状态）。按下触发
`ToggleFullscreen()`，抬起只吞掉不重复翻转（只吞一半会让页面键盘状态错位）。
顶层 WndProc 的 F11 分支保留为兜底（覆盖 `SendMessage` 直投顶层的情况）。
断言：`tool/check_desktop_channels.dart` 从 53 → **55**，新增两条：
「F11 在消息循环里按消息拦下」= 调用点在 DispatchMessage 与 handleWndProcForCEF 之前；
「按下/抬起都吞掉」= `HandleKeyMessage` 里 KEYDOWN→ToggleFullscreen、KEYUP→return true。
实机验证（诊断构建，2026-10-28）：PostMessage 给 FLUTTERVIEW 两次 → 样式
0x14CF0000 → 0x96000000 → 0x14CF0000，来回都正确（修复前同样操作毫无变化）。
残余：真键盘按 F11 的确认还需要用户在场（实机桌面锁屏时无法注入真实按键）。
顺带留下的诊断能力（默认关闭，不写日志）：
- C++：`GARDENDLESS_KEY_TRACE=1` 时把消息循环看到的按键写进
  `%TEMP%\gardendless-keys-native.log`（512 KB 上限，超限停写）；
- Dart：`--dart-define=GARDENDLESS_DIAG=true` 时把页面收到的 keydown/keyup、
  `document.hasFocus()`、桥安装结果写进 `%TEMP%\gardendless-keytrace.log`（同样 512 KB 上限）。
两者合起来能一眼区分「按键没到消息循环」「到了循环但没进页面」「进了页面但游戏没处理」。

`B-72 桌面端「用云端存档（覆盖本机并重启）」点了没反应、也不重启 → 已修（2026-10-28，P0，只改服务端静态文件）→
现象：Windows 桌面端存档冲突弹窗里点绿色主按钮，没有任何反馈；进度不变、游戏不重启。
同一弹窗的「保留本机并上传」「下载备份」都正常，所以不是网络或存档接口的问题。
根因：这个动作被 `confirm()` 挡住了。桌面游戏窗口是 `webview_cef` 的 CEF **离屏渲染**，
插件没有注册 `CefJSDialogHandler`（`grep -rn JSDialog` 在插件源码里 0 命中）；CEF 在
没有 handler 时把 JS 对话框当作「取消」，所以 `confirm()` 直接返回 false，
`useConflictCloud()` 第一行就 return —— 点了等于没点。Android 的 WebView 有原生对话框，
因此只有桌面端中招。
同类隐患（一起修了）：游戏页 iframe 里的存档面板 `admin.html` 的
「只回滚该玩家 / 恢复历史版本 / 删除 / 覆盖上传」也用 `confirm()`，桌面端同样静默失效
（fail-safe，不会误删，但操作没反应）；`conflict.html` 的两个按钮同理。
修法（彻底不依赖宿主实现对话框）：
- `save-api/ui.js`：「用云端存档」改成**同一个按钮点两次**——第一次把文案改成
  「再点一次确认覆盖」并显示黄色警告（5 秒后自动复位），第二次才写 `__pvzAdoptCloud`
  快照并 `location.reload()`；关闭面板时复位上膛状态。
- `save-api/conflict.html`、`save-api/admin.html`：引入同样的 `armed()` 二次确认，
  覆盖 6 个破坏性动作；第一次点击只换文案 + 说明后果。
为什么不去实现宿主的 confirm：`webview_cef` 是三方插件，改它要 vendor + 只能 Windows 构建；
而且 Android/iOS/鸿蒙/桌面四套宿主都得各实现一遍。把确认做进页面本身，一次覆盖全部宿主，
顺带在浏览器里也更友好。
断言：
- 新增 `tools/test-ui-dialogs.js` **21 项**：三个页面不再有 confirm/alert/prompt 调用；
  「用云端存档」仍是「上膛 → 执行」两步、仍然写快照并 reload；`armed()` 状态机
  （首次 false、二次 true、超时复位、不同目标重新上膛）。
- 真实浏览器验证（Chromium + Playwright，stub 掉 `/_save/api/{whoami,load}` 渲染真弹窗）：
  第一次点击 → 文案变「再点一次确认覆盖」+ warn 提示、无 marker；第二次点击 →
  `__pvzAdoptCloud` 写入 `user=42 / gv=0.16.1 / 云端数据（金币 6990）`、提示
  「已记录云端存档，正在重启游戏…」、页面开始重载。
- `node tools/test-sync-offline.js` 473/0 回归；`bash tools/deploy-static.sh --check`
  9 个文件源/线上一致。
部署：纯静态文件，`bash tools/deploy-static.sh` 即可（浏览器版 + App 版
`app-ui.js`/`app-admin.html`），**不用发客户端版本**；用户重进游戏页就生效
（`ui.js` 在每次启动游戏时由客户端拉取）。
残余：冲突/面板里其它依赖 `alert` 的提示（如果有新增）仍要注意同一条约束——
**存档前端不要用原生 JS 对话框**，`test-ui-dialogs.js` 会挡住。

`B-71 Windows 点「退出并自动更新」后加载器消失，之后什么都没发生 → 已修，待发布（2026-10-27，P0）→
现象：点「退出并自动更新」，窗口立刻消失；没有进度窗口、没有重启、日志页看不到结果；
重启后版本号没变，只有 `<资源根>/windows_update_result.json` 里一份 `pending`。
根因（两条独立缺陷，缺一不可，都是「看起来必然成立」的那类假设）：
1. **`ProcessStartMode.detached` 在 Windows 上是空转**：`Process.start` 成功返回一个
   pid，但子进程根本没有执行。真机对照实验（同一组参数、同一个带空格的安装路径）：
   detached → probe 脚本一行没跑、连日志文件都没创建；`ProcessStartMode.normal` →
   立刻正常执行，而且父进程 `exit(0)` 消失 6 秒后子进程仍能写文件。
   所以更新脚本从未启动过，`%TEMP%` 里没有任何 `gardendless-update-*.log`。
2. **`exit(0)` 硬终止触发 fail-fast**：事件日志 `Application Error 1000 /
   0xc0000409 / ucrtbase.dll`（CEF 的线程还在跑，CRT teardown 出错），还留下
   40 MB 的 WER 转储。用户看到的就是「点了更新，应用崩了」。
   （排查时看到两个 11:07 起常驻的 `CefViewWing`，一度以为是崩溃留下的孤儿；
   实际是 **MuMu 模拟器** 的进程，与本项目无关。webview_cef 的 CEF 辅助进程
   与主进程同名（`gardendless_loader.exe --type=...`），所以按进程名断言就能覆盖孤儿。）
修法：
- `WindowsUpdaterScript.start()`：参数拼装集中一份（应用与实机测试共用同一份），
  **普通模式**启动 + 立刻关子进程 stdin + 读掉 stdout/stderr。
- 退出前 **700 ms 存活校验**：脚本秒退就当成失败，界面报
  「更新脚本启动后立即退出」，并撤掉 pending 回执——不再静默消失。
- 退出改走窗口通道 `quit`（原生 `PostMessage(WM_CLOSE)`），不再 `exit(0)`；
  6 秒兜底硬退。
- 更新脚本自带「正在更新」进度窗口（WinForms + Marquee）：等待退出 / 解压 /
  备份 / 覆盖 / 完成；等待期间泵消息，避免十几秒无响应。整段 UI 都是尽力而为
  （失败只写一行 `progress ui unavailable`，更新照常），`-NoUi` 供测试关闭。
- 顺手修两处同类问题：`openWindowsUpdateFolder` 也用了 detached（「打开目录」
  按钮同样点了没反应）；`Invoke-Robocopy` 原来用 `Start-Process -PassThru`，
  PS 5.1 不带 `-Wait` 时 `ExitCode` **恒为 `$null`**，于是失败被当成成功
  （写出 applied 却一个文件都没覆盖，`$rc -ge 8` 的回滚分支永远不触发）。
断言：
- `check_desktop_channels` 38→**53**（启动模式、stdin/流、存活校验、quit 通道、
  WM_CLOSE、进度窗口与 `-NoUi`、泵消息、robocopy 退出码来源、每条失败路径先关窗口）。
- `check_update_manifest` 53→**54**（参数拼装位置 + 普通模式）。
- `tools/test-windows-updater.ps1` 新增第 9 例 **11 项**：用
  `dart run tools/windows_update_spawn_check.dart` 调生产代码的 `start()`，
  父进程 900 ms 后 exit，脚本必须自己跑完 —— 实测 `applied`、exe 被替换、
  downloads 保留、6.2 秒完成，并断言日志里没有 `progress ui unavailable`
  （窗口真的建起来了，不是静默降级）。
- 新增 `tools/test-windows-quit.ps1`（**5 项**）：给主窗口发 `WM_CLOSE`（窗口通道
  quit 走的就是这条路径），断言 15 秒内退出、退出码 0、**没有 0xc0000409
  崩溃事件**、没有残留的加载器/CEF 辅助进程。
残余：用户机器仍是 hlh.27（那一版的更新器就是坏的，应用内更新救不了自己），
hlh.29 由我方用 `tools/upgrade-windows-install.ps1` 就地替换；从 hlh.29 起
应用内更新才可用。

`B-70 Windows 端没有全屏：游戏设置里选「全屏」没有任何效果 → 已修，待发布（2026-10-27，P1）→
现象：Windows 加载器只能窗口化运行；游戏内设置勾选全屏后画面不变，加载器本身也没有全屏入口。
根因（三层，都要看）：
1. 游戏把宿主当成 Electron：资源包里的 `tmppatch.js` 自造 `window.electron`，
   `e_fullScreen` 最终调 `document.documentElement.requestFullscreen()`。
2. 桌面加载器用 `webview_cef` 的 **CEF 离屏渲染**（画面贴成 Flutter 纹理），
   离屏模式下 HTML5 全屏不会改变任何窗口状态；插件里也没有全屏回调
   （`grep -i fullscreen` 在插件源码里 0 命中）。
3. 启动器自身当时没有任何窗口级全屏能力（`windows/runner` 是模板代码）。
修法：
- `windows/runner/flutter_window.cpp` 新增窗口能力通道
  `io.github.dey410.gardendlessloader/window`（`setFullscreen` / `isFullscreen`）：
  边框全屏 = 记下 `GWL_STYLE`/`GWL_EXSTYLE`/`WINDOWPLACEMENT` → `WS_POPUP` +
  `MonitorFromWindow(MONITOR_DEFAULTTONEAREST).rcMonitor` 铺满 → 退出时原样
  `SetWindowPlacement` 还原（含最大化）。
- F11 在 `MessageHandler` 里**先于** Flutter/CEF 处理，状态变化用
  `InvokeMethod("onFullscreenChanged")` 推回 Dart，界面按钮不会和真实窗口脱节。
- `lib/src/services/window_service.dart`：Windows-only，桌面其它平台静默降级，
  `MissingPluginException` 当作「平台没这个能力」。
- `lib/src/services/desktop_fullscreen_script.dart`：页面侧把
  `requestFullscreen`/`exitFullscreen`/`webkit*` 转发给 `window.gardendlessDesktop`
  （Dart 注册的 JS 通道），并伪造 `document.fullscreenElement`——不覆盖它，
  游戏用 `electron.isFullscreen()` 判断状态会永远返回「不是全屏」，第二次点还是进入。
- `desktop_game_page.dart`：每次 `onLoadEnd` 重装桥（reload 会清掉 JS 通道）、
  工具栏加全屏按钮、离开游戏页时强制退出全屏（否则加载器留在无边框全屏）。
断言：
- `check_desktop_channels` 23→**38**（原生通道/WS_POPUP/还原/F11 顺序/注入脚本/页面接线）。
- 新增 `tool/check_fullscreen_script.mjs` **23**：在 Node 里跑注入脚本，用假 DOM 验证
  单次切换、二次退出、F11 回灌、无通道时不假装成功、重复注入、webkit 前缀。
- 新增 `tools/test-windows-fullscreen.ps1` **13**（只能 Windows 跑）：给真实窗口
  `PostMessage(WM_KEYDOWN, VK_F11)`，实测 style 从 `0x4CF0000` → `0x96000000`
  （WS_POPUP）、rect 从 `10,10 1044x720` → `0,0 1024x768`（显示器矩形），退出后逐字节还原，
  连续切换 3 次不漂移。
残余：**游戏内点「全屏」→ JS 通道 → Dart 这一段无法自动化**（要真的点开游戏设置），
需用户在实机点一次确认；多显示器与 DPI 缩放未在真机覆盖（ssh 会话里只有一块 1024x768
虚拟显示器，且是隐藏窗口验证）。

`B-69 桌面端用 `cmd /c start` 打开链接，URL 含 `&` 时被 cmd 截断/当命令分隔 → 已修（2026-10-27，P1）→
现象：带多个查询参数的链接（OAuth 回调、带跟踪参数的公告/更新链接）点开后只打开前半段。
Windows 实测：URL `http://127.0.0.1:<port>/game?uid=42&profile=slots-1&ver=hlh.26` 经
`cmd /c start` 只有 `/game?uid=42` 到达浏览器；`&` 之后的内容被 cmd 当成**独立命令**执行
（`cmd /c echo LEFT url RIGHT` 的输出只剩 `LEFT https://example.com/?a=1`，紧跟
「'b' 不是内部或外部命令」）——既是功能缺陷，也是命令注入面。
根因：`cmd /c` 走的是 shell 解析，`&` 是命令分隔符，与 URL 无关。
修法：Windows 分支改为 `rundll32 url.dll,FileProtocolHandler <url>`（ShellExecute，
参数按 argv 传递，不过 shell）；失败（杀软拦 LOLBin）退回
`powershell -NoProfile -Command "Start-Process -FilePath '<url>'"`（单引号内不解析 `&`，
内部单引号双写）。
验证：同一本地 HTTP 服务器抓请求，`cmd /c start` → `/game?uid=42`（截断）；
rundll32 → 完整路径；powershell 兜底 → 完整路径。断言：`check_desktop_channels` 21→23。

`B-67 Windows 更新过程对用户完全不可见（无进度、无结果）→ 已修，待发布（2026-10-27，P1）→
现象：点「退出并自动更新」后应用立刻消失，更新期间无任何提示；失败（尤其回滚、
脚本被杀软拦下）时也没有任何反馈，用户只能靠版本号猜有没有更新成功（用户实测反馈）。
根因：`applyWindowsUpdate()` 写完脚本就 `exit(0)`，覆盖发生在退出之后；脚本虽然写了
`%TEMP%\gardendless-update-*.log`，但没有任何代码把它读回来；`exit 2/3/5` 这几条失败
路径连应用都不重新拉起，用户面前只剩空桌面。
修法：
1. 脚本新增 `-Result <json>`、`-FromVersion`、`-ToVersion`：**每条**退出路径都写
   `{status: applied|rolled-back|failed, code, message, fromVersion, toVersion, logFile, at}`；
   失败路径一律 `Relaunch` 把加载器拉回来。
2. Dart 在退出前写一份 `windows_update_result.json`（status=pending），脚本覆盖成终态；
   启动时 `_consumeWindowsUpdateResult()` 读一次、删掉、转成提示：
   `applied` → 「已更新到 X」；`rolled-back` / `failed` / `pending` → 各自的失败提示
   （带 userErrorCatalog 里的下一步动作）；同时写 `windows_update_result_consumed` 日志
   （含 logFile 路径）。
3. 退出前把 `AppUpdatePhase.installing` 刷出去并延迟 900ms 再 exit，设置页能看到
   「正在退出并安装更新…」。
断言：`check_update_manifest` 32→**53**、新增 `check_windows_update_result` **38**（回执解析、
BOM/坏 JSON/未知 status、logCode 与 catalog 一致）。
**Windows 实机复测（2026-10-27）**：`tools/test-windows-updater.ps1` 49/0，覆盖正常覆盖、
坏 zip、包缺 exe、备份失败、复制失败回滚、盘符根目录、120 秒未退出七条路径。实测又修掉三处：
1. robocopy 默认「重试 100 万次 × 30 秒」——目标文件被占用时脚本**永久挂住**（实测进程
   在跑、没有任何输出、应用不重启）。改为 `/R:2 /W:1`，两次失败即回滚。
2. 备份失败留下 /MIR 半成品备份（可能几百 MB）→ 清理。
3. 回滚成功后备份没删（同样几百 MB）→ 删除；而**回滚失败时必须保留**（那是用户唯一完整的
   旧版本），提示里给出备份路径。
残余：需 Windows 机器构建 hlh.27 并在实机走一遍成功、失败、回滚三条路径。

`B-68 下载目录落在资源根里，用户把资源根设成 downloads 时出现 downloads\\downloads → 已修，待发布（2026-10-27，P2）→
现象：Windows 用户的资源根被设成 `D:\Program Files\gardendless-loader\downloads`，资源包
被下到 `...\downloads\downloads\`，位置反直觉、也不好清理。
修法：桌面端下载目录默认改成**加载器自己的目录** `<exe 所在目录>\downloads`（创建后
真写一次探测可写性，不可写则退回资源根下的 `downloads`）；移动端不变。
连带改了更新脚本：备份/回滚的 robocopy 增加 `/XD "<install>\downloads"`，否则 1 GB+
的资源包会被整份备份，回滚的 `/MIR` 还会把它当「新版本多出来的文件」删掉。
断言：`check_update_manifest` 覆盖「下载目录默认落在加载器目录并可回退」与 `/XD` 排除。
另：更新脚本的备份/回滚 `/XD` 会把同名目录排除——如果用户把资源根设成 `<安装目录>\\downloads`，
两者重合时资源不会被备份（也不需要，更新包不含该目录），但要注意这是有意的行为。
残余：旧位置已有的半包不会自动搬（重新下载即可）。

`B-66 Windows 启动必崩：初始化末尾直接调只有移动端实现的平台通道 → 已关闭（2026-10-27，P0，hlh.26）→
现象：Windows 包一启动就弹「应用初始化失败」。日志
`MissingPluginException(No implementation found for method incomingZip on channel
io.github.dey410.gardendlessloader/resource_zip_importer)`，停在
`app_controller.dart:1258`（`_resourcePickerService.incomingZipName()`）。
根因：`resource_zip_importer` / `shortcuts` / `external_browser` 三个通道只在
Android(Kotlin)/iOS(Swift)/鸿蒙(ETS) 实现，`windows/runner` 一个平台通道都没有，
桌面端 `invokeMethod` 必抛 MissingPluginException；这三行又正好在初始化末尾，被
`initialize()` 的兜底 catch 接住，于是变成整页初始化失败。旁证：该机 `slot-a`/
`slot-b` 为空、`downloads` 里只有一个没有 EOCD 的 14 MB 半包 —— 从未成功初始化过。
修法：`ResourcePickerService.incomingZipName/discardIncomingZip`、
`ShortcutService.take/publish` 桌面端直接返回，并把 MissingPluginException 当作
「平台没有这个能力」；新增 `ExternalUrlService` 统一外部链接（Windows
`cmd /c start`、macOS `open`、Linux `xdg-open`、移动端走通道），
`app_controller.openTokenIssuePage` 与 UI 的公告/更新链接都改走它（顺带修掉
Windows 点链接没反应）。
断言：新增 `tool/check_desktop_channels.dart` **21 项**（源码契约：桌面端必须先挡掉
或忽略缺失通道；外部链接必须走统一入口；初始化仍读取待处理 ZIP 与快捷方式）。
残余：`Program Files` 下的安装目录更新仍需提权；Windows 真机完整一局未验。

`B-65 iOS/OHOS 原生宿主没有内联本地存档版本 guard → 已关闭（2026-10-26，P1，hlh.25）→
Dart 把 `__local_save_guard.js` 写到 appRoot，Android/桌面端会注入；本轮把
iOS `GameHostController` 与 OHOS `GamePage` 也接入：从
`appRoot/__local_save_guard.js` 读取，追加在 game_bridge 脚本之后的同一
document-start 注入。两端 session 增加 `localSaveGuardRequired`（旧 JSON 缺字段
默认 false）。required 时缺失/空白/读取失败必须阻止启动：iOS 记录
`local_save_guard_unusable` 后抛错，`loadView` 置 `launchFailed`、装占位视图并
把退出延后一轮（此时 WebView 未创建；`viewDidLoad`/`cleanupWebView` 容忍 nil）；
OHOS 抛 `LocalSaveGuardUnusableError`，`aboutToAppear` 复用
`game_page_initialization_failed` 写退出结果，`onControllerAttached` 在
`launchFailed` 时拒绝 `loadUrl`。契约断言（源码级）：
`check_game_host_contract` 覆盖两端字段默认值、guard 路径、required
fail-closed、追加顺序、失败后不加载，共 11 条（83→94）。
残余：本机无 Xcode/OHOS SDK 与设备，两端未编译、未实机；两端仍未注入
`__save_bridge.js`（B-64 范围外的既有行为，未改变）。`
