# HANDOFF — GardendlessLoader 个人构建线

> 这份文档是接力主入口。**先读完本文档，再按第 6 节的顺序读 docs。**
> 机器可读状态在 `state.json`；契约在 `PROTOCOL.md`。三者冲突时以 `PROTOCOL.md` 为准。

## 1. 这是什么项目

`GardendlessLoader` 是《植物大战僵尸》网页版（PvZ GE / Gardendless）的第三方启动器：
Flutter 写外壳，原生 WebView 承载游戏。上游作者是 `Dey410`，我们在其基础上做了一条
**个人构建线**（版本号带 `-hlh.N`），把「离线可玩 + 云存档 + 双端 + 自动更新」补齐。

一句话定位：**把网页游戏变成「装了就能玩、存档跟着账号走、资源可离线」的客户端。**

三个远端，别搞混（细节见 `docs/02-branches.md`）：

| 远端 | 仓库 | 分支 | 用途 |
|---|---|---|---|
| `upstream` | Dey410/GardendlessLoader | `main` | 作者主线，**只读参考，不推不改不提 PR** |
| `origin` | HLH2023/GardendlessLoader | `feature/app-update` | 我们的公开 fork，**日常开发就推这里** |
| `private` | HLH2023/gardendless-app | `main` | 私有仓，代码镜像 + APK/Windows 产物 Release |

服务端另有一个私有仓 `HLH2023/pvzge-server`（存档 API + 网关脚本），不在本仓库内。

## 2. 当前状态（截至 hlh.35）

- **版本** `0.9.0-hlh.35+90035`，已发布：APK 58,652,226 B（`f2f1f269…`）、
  Windows x64 zip 190,980,540 B（`9c1e5b3a…`）。两份更新清单 latest 均为
  `0.9.0-hlh.35` / 90035，GitHub Release `v0.9.0-hlh.35`。hlh.32–hlh.35 修的是
  B-76/B-77「桌面端快捷键」：先修键盘引导时序，再修 `event.code` 为空
  （Cocos 按 code 映射）——用户已实机确认数字/字母键生效。
- **Windows 全屏**：原生窗口通道做边框全屏（`WS_POPUP` 铺满所在显示器，退出时
  精确还原），三条入口——游戏内设置的全屏（注入脚本转发 DOM 全屏 API）、
  游戏页工具栏按钮、F11；离开游戏页自动退出全屏。实机用例
  `tools/test-windows-fullscreen.ps1` **13/0**（用发布包跑：style
  `0x4CF0000→0x96000000`，rect `10,10 1044x720→0,0 1024x768`，退出逐字节还原）。
- **Windows 更新链路已在真机验证**：`tools/test-windows-updater.ps1` **63/63**
  （正常覆盖 / 坏 zip / 包缺 exe / 备份失败 / 复制失败回滚 / 盘符根目录 /
  120 秒未退出 / **用本次正式发布包跑完整更新**，8.7 秒 / **第 9 例用生产代码
  真正启动脚本**——父进程 900 ms 后退出，脚本自己跑完 6.1 秒且进度窗口未降级）；
  另加 `tools/test-windows-quit.ps1` **5/5**（`WM_CLOSE` 干净退出、无崩溃事件）；
  `tools/smoke-windows-build.ps1` **6/6**（发布包解压后启动 12 秒存活、
  事件日志无崩溃记录）。两个脚本只能在 Windows 上跑，不计入基线。
- 实机验证顺带修掉三处脚本级缺陷：robocopy 默认「重试 100 万次×30 秒」会在
  文件被占用时**永久挂住**（已改 `/R:2 /W:1`）；备份失败留下半成品备份；
  回滚成功后不改删除备份（现在只在「回滚也失败」时保留，因为那是唯一完整的
  旧版本）。详见 B-67。
- **B-65 已修（源码级）**：iOS `GameHostController` 与 OHOS `GamePage` 现在从
  `appRoot/__local_save_guard.js` 读取 Dart 生成的版本 guard 并追加到
  document-start；`localSaveGuardRequired` 两端口径与 Dart/Android 一致（旧
  JSON 缺字段默认 false），required 时缺失/空白/读取失败阻止启动（iOS 写
  `local_save_guard_unusable` 后走 `launchFailed`，OHOS 复用
  `game_page_initialization_failed`）。本机无 Xcode/OHOS SDK，**未编译、未实机**。
- **Web/App 游戏内存档面板已统一（2026-10-26 13:42 静态部署）**：原来的
  「上传本机存档」在 App 面板里被隐藏（iframe 跨源读不到游戏 localStorage）。
  现在按钮移到游戏页面板标题栏，由 `window.__pvzManualUpload()` 读取本机键并
  走 `send()` 合并上传（baseVer/冲突/玩家回填，非 force）；iframe 内嵌时不再
  重复显示按钮，单独打开管理页仍保留原按钮。`sync.js 165258 B`、
  `ui.js 43295 B`、`admin.html 43779 B`；`deploy-static --check` 9/9。
- **更新过程可见化（hlh.27 已发）**：脚本每条出口写 JSON 回执、失败也重拉
  加载器、启动后提示成功/回滚/失败；下载目录默认落到 `<安装目录>/downloads`；
  `ExternalUrlService` 弃用 `cmd /c start`。详见 B-67/B-68/B-69。
- **Web 登录后黑屏已热修（2026-10-26 15:23 静态部署）**：第十轮的「顶层
  `window.stop()` + 同源 iframe」方案在真实浏览器里 rAF 完全不触发，iframe 里的
  cocos 帧数恒为 0。现在删除 iframe，改成写者资格传递（pass），游戏始终跑在顶层
  文档；第二标签页显示可见提示且不写存档。详见第 2 节第十一轮与 B-64。
  `sync.js 171699 B`、`app-sync.js 174631 B`；`deploy-static --check` 9/9。
- **服务端** `pvzge-server` main `95defc2`：hlh.24 冲突面板与 App 下载桥；
  hlh.23 的 Web 版本分区、冲突页下载、管理页手动上传版本、静态部署脚本均在。
  静态文件已用 `deploy-static.sh` 落地并 `--check` 一致。
- **2026-10-26 自动上传修复（已部署）**：管理页手动上传现在同步推进同源游戏页的
  玩家基准；服务端对内容未变的玩家返回 `profileUnchangedIds`。另修非玩家键
  纳秒版本号被 JS double 舍入导致的永久 `stale_base`（`same_save_version()`）。
  Web E2E 用手动上传 → 游戏自动上传 777/666 验证无冲突；运行时/启动冲突双向
  已验；Android 登录、Saves 页两名玩家、历史与单玩家回滚已验。
- **2026-10-26 手工复核第五轮（静态已部署，server.py 待重启）**：在 oracle-sol
  之外先自己逐段复核，找到并修掉以下问题：`/save` 只信页面启动时 `/load` 确认的
  uid（`expectedUid`），运行中换号会被服务端 403 拒绝而不是写进新账号；管理页
  手动上传先比对 `__pvzSyncUser`，并把 uid 随请求发送；force 的 200 但正文不可
  解析不再当成功清队列；云端只有更新版本时不再把本机旧档塞进 pending；整包
  回滚恢复被删玩家的原 profileId（镜像保留 ID；旧快照按位置/名字从 tombstone
  找回），管理员代回滚不再把 ownerUid 写成管理员；本机已删除的玩家在单玩家
  回滚后重新插回数组和 pending，避免下一次上传把管理员的回滚删掉；删除玩家键
  时清掉旧回滚标记；回填 profileId/采用云端等原生的写入补 generation 写后回滚。
  Web/App sync-offline 225、admin 19、save-versions 137、sync-live 9、
  concurrency 28、cloud 108 全过；静态 9 项部署一致。**本轮 server.py 改动尚未
  重启容器加载，生产仍在跑上一版服务端**（见收据 needsHermes）。
- **2026-10-26 手工复核第六轮（静态已部署，server.py 待重启）**：继续在
  oracle-sol 之前逐段复核，修掉：换号归档先写后删、localStorage 写满时会丢掉
  唯一本机存档（改为逐键读回校验、失败中止换号并保留旧账号存档）；
  `takeOverDocument` 的 generation 写失败会无限 reload（改为读回校验、失败降级
  启动）；回填 `__pvz_profile_id` 时把「云端有、本次没发」的玩家按提交后位置
  安到本机新玩家上（只回填本次发过的同位置、内容未变条目）；升级游戏后旧版本
  pending 静默覆盖新版本 exact 存档（跨版本丢弃 exact 键的 pending，只允许
  migrated/none 搬运）；冲突页「保留此设备」直接 `/save` 不带 uid（上传前
  重新 `/load` 复核账号 + `expectedUid` + 响应身份校验），冲突页摘要转义；
  管理页/冲突页换号提示；玩家键设备元数据移入 profile 锁且只记真正写入的
  请求，避免覆盖 `restoredAt`。Web/App sync-offline 243、admin 19、
  save-versions 142、sync-live 9、concurrency 28、cloud 111 全过；静态 9 项
  一致（2026-10-26 04:03）。**server.py 已于 2026-10-26 09:25 重启加载**，
  生产 `expectedUid` 403/正常写入、真实 `akadmin` `/load`、cloud-saves 111 冒烟通过。
- **2026-10-26 oracle-sol 最终复核修复（静态已部署，server.py 待重启）**：独立复核
  判定上一版不可交付（8 类 P1）。本轮修掉 7 类并补断言：generation 写失败时
  启动恢复只落地内容、不发布基准/不装 hook，运行期「用云端存档」强制开新
  epoch；换号改为完整事务（旧账号归档 + 目标游戏键/状态/pending 逐项读回，
  任一失败回滚旧账号，目标归档成功后才删）；写后接管不再把 prev 写回（ABA
  会盖掉赢家），改为删除自己那份 + `__pvzResync` 指纹，启动按云端重建，
  pending 内容不同则保留重放；采用云端快照/运行期采用都写后读回，失败保留
  marker/pending；`__pvzPendingGv` 记录队列版本，降级全丢、升级只丢 exact；
  版本保护备份键改为账号+版本，并归档/合并 `__pvzPending:<gen>` 槽；`/load`
  每键内容、mtime/纳秒版本、回滚元数据同锁读取，`/profile/restore` 增加
  毫秒级 `restoredProfileEvents`（连续回滚 A/B 不再只看到最后一个），
  tombstone 取消 100 条截断；管理页上传同时捕获数据与身份快照，预检和发送前
  各复核一次。Web/App sync-offline **287**、save-versions **159**、
  cloud-saves **115**、admin 19、sync-live 9、concurrency 28、guard **42**、
  game-host-contract 76 全过；总 **902**。静态 2026-10-26 10:08 部署并 9 项
  一致；`server.py` `5b5bf221…` 已于 2026-10-26 10:10:45 重启加载，生产
  expectedUid 403/正常写入、真实 akadmin /load、连续 A/B 回滚事件、cloud-saves
  115 均通过。多标签页真正的跨上下文
  串行化仍未实现（B-38/B-53，oracle 判 P1）。

- **2026-10-26 第八轮：oracle-sol 二次复核后的手动修复（静态 10:57 已部署）**：
  二次复核列出 9 条 P1 + 1 条 P2，本轮修掉 8 条 P1 与 P2-1，并补跑真实断言：
  单玩家回滚接管失败不发布新基准、进入停用；换号 `__pvzSyncUser` 写后读回、
  失败整体回滚；账号归档键加游戏版本段，低版本不恢复高版本账号内容；
  `writePendingRaw` 不再改写来源版本，legacy 迁移/carry 不改方向；
  adopt 只在全部内容落地后删旧 pending；恢复/采用云端部分写失败时回滚已落地
  的键；停用云同步时仍装「只记本机 pending」的 hook；版本保护三类归档任一
  失败时阻断目标版本（读/写门闩 + `window.stop()` + 提示），不再让低版本
  读到高版本活动存档；管理页迟到 ACK 写共享基准前三次复核身份快照。
  额外手工复核发现并修：恢复写循环中途被接管直接 reload，不再带着半状态启动。
  Web/App sync-offline **339**、save-versions **159**、cloud-saves **117**、
  admin **21**、sync-live **9**、concurrency **28**、guard **65**、
  game-host-contract **76** 全过；总 **981**（服务端 673 + 客户端 308）。
  剩余 P1 为 B-53（Web 多标签页无真正跨上下文互斥）；第九/十轮已用 Web 顶层锁 + 游戏 iframe 关闭。

- **2026-10-26 第十轮：Web 顶层锁 + 游戏 iframe，修 oracle-sol 第五轮 P1**：
  第九轮把 `armWriterGate()` 放在 `sync.js` 末尾，第二个标签页会先跑完 `/load`、
  恢复与 generation 推进，等锁拒绝时正在游玩的标签页未上传改动已被判废。本轮
  改为 Web 顶层只请求 `pvzge-game-writer` 生命周期锁：拒绝就不 boot、不创建
  iframe；grant 后创建同源 iframe，游戏在子 frame 执行同一份 `sync.js`，父页
  持锁到卸载。App/本地回环 origin 仍走同步 boot。写入门闩改为 pending 时所有
  键进影子区；blocked 后 ACK/失败回调/重试/基准/游戏键全部拒绝。运行期采用
  云端补了逐键/meta/玩家基准回滚，回滚失败则停止本局写档。新增 sync-offline
  `[86]-[88]`，Web/App 各 **411/0**；Oracle 还指出 `APP_SYNC` 只切了 [5] 的源，
  现在整套 411 条按 `DEFAULT_SRC` 跑 App 变体，并删掉了 `|| true`。
  同轮 P1-4/P1-5：服务器清单请求在写缓存/登出之前复核令牌+服务器+代际，换服
  清空 `_remoteManifest`；版本保护 guard 改为临时文件→读回→rename→再读回，
  失败抛出阻止启动，新增 `localSaveGuardRequired` 贯通 Dart→Kotlin，Android
  required 时缺失/空白/读取失败 fail closed。客户端套件因此
  `game-host-contract 73→83`；补 B-65 后再到 **94**。手动上传入口统一后
  sync-offline 411→**441**，总基线 **1091**（服务端 775 + 客户端 316），
  Android JVM **46/0**，`flutter analyze` 无告警。
  B-53、B-65 均已关闭。
  同轮此前已删除启动器在线游玩模式，只保留本地资源包；**登录、云存档、
  资源下载、APK/Windows 更新检查保留**，旧 `playMode`/`desktopOnlinePort`
  显式忽略。

- **2026-10-26 第十一轮（热修）：撤掉「游戏 iframe」，Web 改回顶层文档 + 写者资格传递**：
  第十轮方案在真实浏览器里就是**线上黑屏**。根因：父文档在 `</head>` 里
  `window.stop()`，`document.body` 从未生成，**整棵文档树的 rAF 一次都不触发**
  （真实 Chromium 实测 2 秒 0 次回调）；装进去的同源 iframe 里 cocos 资源虽然
  全部 200 加载完，但 `cc.game.isPaused()===true`、`director.getTotalFrames()===0`、
  `getScene()===null`——一帧不画。对照：同一份 `index.html` + 同一份注入脚本在
  顶层文档直接跑是 `frames=412 / mainScene`；线上 14:43 日志也吻合（游戏资源
  全部 200 之后没有任何后续请求）。
  改法：删除 iframe 宿主（`writerHostChild`/`startWriterHost`/
  `mountWriterHostFrame`/`blockWriterHost`/`writerHostOverlay`/`hideWriterHostOverlay`），
  改为**写者资格传递（pass）**：公网 Web 无 pass 的顶层只做一次极短交接——
  `ifAvailable` 拿 `pvzge-game-writer` → `sessionStorage` 写一次性 pass →
  `window.stop()` → `location.replace(location.href)`（锁持有到卸载）；带 pass 的
  顶层消费 pass 后走**原来的顶层 boot**（与 App/桌面同一条路径），游戏始终在顶层
  文档里。锁被占时**只渲染全屏提示、绝不 stop**（stop 后提示层同样画不出来），
  并提前吞掉 4 个存档键的 `setItem/removeItem`；pass 页在 `armWriterGate` 拿不到
  锁时 250ms×8 重试，躲开旧文档卸载与锁释放的竞态。
  验证（真跑）：`test-sync-offline` Web **473/0**、App 生成物 **475/0**、
  `test-admin-baseline` **21/0**、部署后 `test-cloud-saves` **117/0/0**；
  真实 Chromium（非 localhost 域名 + 非单实例宿主）修复后 `iframes=0`、
  `frames=463`、`scene=mainScene`、`writerLock=granted`；第二标签页提示层
  1100×673 可见、不 boot、存档键写入被吞。静态已部署，`--check` 9/9。
  总基线 **1123**（服务端 807 + 客户端 316）。

- **存档冲突直接可操作（hlh.24）**：冲突不再只给一条横幅，打开即显示本机/云端
  摘要与「下载最新云端 / 保留本机并上传 / 启动阶段覆盖本机 / 稍后处理」；
  运行中冲突不提供覆盖；保留本机带 `force` + `gameVersion`，并以服务端
  `saved` 为准，零接受会报错并保留本机改动。App 面板单条下载经 postMessage
  交给游戏页导出，Android 不再点了没反应；冲突面板按 `data-pvz-ui` 放行触控。
- **21:9 原生适配（hlh.22）**：`跟随屏幕` 直接使用真实窗口比例，不裁切、
  不加 16:9 黑边；启动器短屏可滚动、存档页双栏、游戏内面板短屏全屏。
- **Windows 桌面宿主修复（hlh.22）**：`GameHostPlatform` 增加 `dart-desktop`，
  Windows 不再在「游戏」页抛 `Unsupported operation`。
- **Web/App 存档面板（hlh.23）**：Web sync 从页面标题兜底版本号；冲突页按
  gameVersion 读写并支持下载云端 JSON；管理页手动上传写当前版本；普通用户
  可见面板；删除独立「↑ 上传」按钮。Android 原生触控适配器放行
  `data-pvz-ui`，面板按钮/关闭不再被 click 吞掉；App iframe 用服务器绝对地址，
  离线包/Windows 不再空白。
- **存档页修复（hlh.20）**：服务端把 legacy 老存档作为可继承来源，下载新资源包后
  不再显示 0 条；游戏内「存档」按钮对所有用户开放（与 Web 端同一套面板），
  独立的「↑ 上传」按钮移除；启动器只读云端，自动上传只在游戏运行时发生。
- **hlh.18 的 Windows 包无法启动**（原生日志通道在 Windows 无实现，`runApp` 之前
  抛 `MissingPluginException`）。hlh.19 改为日志失败降级，并已在 Windows 实机
  解压新包启动验证：进程存活、不再有该异常、支持目录已创建。
- **能力矩阵**

| 能力 | Android | Windows |
|---|---|---|
| 本地离线游玩（资源包在本地） | ✅ | ✅（本轮打通） |
| 在线游玩（服务端代理 + Bearer） | ❌ 已删除（2026-10-26，只保留本地资源包） | ❌ 已删除 |
| 云存档（按游戏版本分区、向下兼容） | ✅ | ✅ |
| 资源包管理（安装/切换/删除/改路径/迁移） | ✅ | ✅ |
| 本地 ZIP 导入 | ✅ 原生 | ✅ **自写流式解压** |
| 启动器内登录 | ✅ 原生登录页 | ✅ 浏览器签发 + 粘贴令牌 |
| 自动更新 | ✅ 下载 APK 安装 | ✅ 检查/下载/校验/退出并自动替换（失败回滚） |

- **hlh.35（2026-10-28）快捷键最终修复**：按键早已到达页面，但
  `webview_cef` 把整条 `lParam` 当 `native_key_code`，Chromium 算出的
  `event.code` 是空字符串；Cocos 的键盘监听绑在 `#GameCanvas` 且只认
  `event.code`。现在在 window 捕获阶段校正 code 并重派发到画布（原生事件
  截住，不双份；真实输入框不拦）。新增 `check_keyboard_script` 10 项，
  基线 1305（服务端 828 + 客户端 477）。
- **hlh.32（2026-10-28）键盘引导时序**：旧脚本在 `document.body` 出现前就写
  「已安装」标志，注入落在解析中时探针被移走、焦点丢失，而 loadEnd 的第二次
  注入被标志挡掉 → CEF 的 `current_focused_browser_` 永远为空。现在只有探针
  真的挂上并聚焦成功才算完成；`setClientFocus(true)` 提前；loadEnd 1.2s 后
  再强制补焦一次；新增 `keyboard.log` 诊断。基线 1292。
- **hlh.31（2026-10-28）游戏内退出卡死**：游戏把退出实现成 `window.close()`，
  CEF 离屏浏览器被销毁后 `webview_cef` 的 `OnBeforeClose` 是空实现，Flutter
  仍持有该浏览器 → 整窗未响应。注入脚本接管 `window.close` → `window:closeGame`
  → 走「返回」同一条收尾路径，不销毁浏览器。基线 1288。
- **hlh.30（2026-10-28）桌面端键盘/全屏**：输入法会把按键消息的 `wParam`
  换成 `VK_PROCESSKEY`，宿主未还原就转给 CEF（页面只收到 `0xE5`）；另外
  `webview_cef` 只在渲染进程上报焦点节点变化后才肯转发按键，页面没有可聚焦
  元素时键盘全丢。已用 `ImmGetVirtualKey` 还原键码 + 页面加载后聚焦一个隐藏
  输入框解决；F11 改为在消息循环里按「消息」拦截（真实按键投给子窗口
  `FLUTTERVIEW`，顶层 WndProc 收不到）。游戏页顶部工具条改成 **F10** 显隐，
  不再鼠标划过就弹出。基线 1287（服务端 828 + 客户端 459）。
- **B-72（2026-10-28，仅静态文件）**：桌面端存档冲突弹窗的「用云端存档（覆盖本机并重启）」
  点了没反应——宿主是 CEF 离屏渲染、没有 JS 对话框实现，`confirm()` 恒为 false。已改成
  「同一按钮点两次」并把 `admin.html`/`conflict.html` 的 6 个破坏性动作一起改掉；
  只改了服务端静态文件（`bash tools/deploy-static.sh`，已部署并 `--check` 一致），
  **没有发客户端版本**，用户重进游戏页即生效。
- **工作树已提交（2026-10-28）**：hlh.25–hlh.35 合为一个代码提交 `5ee2aaa`
  + 交接文档提交 `ab3387a`，已推 `origin/feature/app-update` 与 `private/main`；
  服务端仓 `/home/hlh/pvzge` 提交 `8a5e343` 已推 `pvzge/main`。发版仍走本地产物
  + 服务端分发目录，与 git 提交无强绑定，但新会话不要误以为「工作树干净 = 已发布」。
- **测试基线 1259 项**：服务端 807（117+28+159+473+9+21）+ 客户端 452
  （42+63+11+94+54+38+9+65+53+23）。另有 Windows 实机 63+13+5 项不计入。
  `cloud-saves` 117 已部署后复跑；`desktop-zip` 11
  用文档里的 fixture 生成后复跑；Android JVM 另有 46 项。另有真实 1.31 GB
  资源包压力用例（`tool/stress_real_pack.dart`）：8240 文件 / 6.9 s /
  峰值内存 294 MB。
- `flutter analyze` 无告警；APK v1+v2+v3 三签。
- **安全边界**：游戏页面只持有 3 小时存档会话令牌；设备令牌留在原生/本地服务器侧
  （`__sync_native_token`，0600）。历史存档每个（用户/版本/键）保留 300 份，从最旧删起。

## 3. 这次要做什么（任务 R-20261025-04）

标题：**多玩家云存档 + 存档页版本来源修正 + Web 单标签页 + 删除在线游玩**

> 交付状态（2026-10-26 13:35）：客户端/服务端代码与本地测试完成；已按前六轮
> `oracle-sol` review 修复 P0/P1，第八轮修掉二次复核的 8 条 P1 + P2-1；
> 第九轮上 Web 单标签页门闩并删除启动器在线游玩模式；第十轮按 oracle-sol
> 复核修掉 5 条 P1（Web 顶层锁+游戏 iframe、blocked 迟到副作用、运行期采用
> 云端回滚、迟到 401、guard fail closed），只保留本地资源包，云存档/登录/
> 资源下载/更新检查保留。总基线 **1259**（服务端 807 + 客户端 452），
> Android JVM **46/0**。静态 2026-10-26 12:41 部署并 9 项一致；
> `server.py` `5b5bf221…`（125080 B）已于 10:10:45 重启加载；生产冒烟与连续
> 回滚事件通过，cloud-saves **117/0/0**。B-53、B-65 已关闭。
> Web E2E 使用临时 authentik 账号完成（多玩家、手动上传后自动上传、运行时/
> 启动冲突双向、账号切换隔离），并用真实登录态验证 Web 顶层锁+iframe 与第二
> 标签页阻断；Android 调试包完成登录、Saves 页两玩家、历史与单玩家回滚。
> APK `0.9.0-hlh.25` 与 Windows zip 已从最终代码重建并发布（GitHub Release +
> 服务端清单）；Android 本地资源包首屏仍在 3 GB 模拟器 ANR，待真机复测（B-33）。

按优先级：

1. **P0 — 一个账号只能有一份玩家数据**。云端把 `PvZ2_PlayerProperties` 整包当一个
   文件，改 A 会把 B 的 revision 一起推进。现在服务端拆成
   `profiles/<uuid>.json` + 原子 `profiles.json` manifest；游戏仍收发数组，
   `/load` 注入 `__pvz_profile_id`，`/save` 按 `changedProfileIds` /
   `baseProfileVer` 逐玩家合并，删除只认显式 `deletedProfileIds`。
   历史/回滚按玩家独立（`/profile/history`、`/profile/restore`）。
2. **P0 — 用户名不是所有权**。`X-Authentik-Uid` 经 nginx 注入，服务端在
   `identity.json` 绑定 username 目录；同名不同 uid 直接 403。令牌记录带 uid，
   `REQUIRE_UID=1` 时旧令牌要求重新登录。
3. **P0 — 存档版本来源混用**。存档页默认跟随游玩形态，但本地查看用
   `currentGameVersion`，在线查看用服务器清单版本；后者取不到时返回
   `online_version_unavailable`，本地没资源时返回 `local_resource_missing`，
   **都不再退回 legacy**。页面允许手动切换查看分区，但不改变运行中的会话。
4. **P1 — 桌面端口随机**。本地/在线各自持久化固定端口，origin 不再每次启动变化；
   端口被占用时明确失败，不静默换一个新 origin。CEF 磁盘缓存仍需原生补丁
   （B-22，Windows 实机验证）。
5. **P1 — 普通用户不能回滚**。移除 `/restore` 前的全局 admin 门禁，改由
   `can_manage()` 按目标校验；普通用户可以回滚自己的存档。
6. **Review 修复（oracle-sol）**：
   - 新玩家首次保存后把服务端分配的 `profileId` 回填本机；无 ID 的连续编辑
     不能被变更集静默丢掉。
   - tombstone 不能被旧设备按 ID/位置复活；现代协议缺 revision 必须冲突。
   - sync 只推进「本机真正持有」的 revision；未见过的云端玩家不进删除集。
   - 管理页玩家摘要 coin/gem 输出编码（存储型 XSS）。
   - 已绑定目录默认拒绝无 uid 请求；首次绑定加锁；`IDENTITY_CLAIM=strict`
     阻止旧目录被同名请求自动认领。
   - 本机版本保护按版本归档/恢复，连续启动同版本不重复清空；换账号时归档
     上一账号的本地存档与 pending，`/load` 失败时不上传。
   - 单玩家回滚只替换该玩家，B 的 pending 保留；`force` 不再隐式删除未见玩家。

**不做**：改上游分支、把服务器地址/令牌写进仓库、重启 core / 动 frpc(.157) /
动路由(.41)、真实用户 uid 目录迁移（B-23）、Windows CEF 原生补丁（B-22）。

## 4. 验收标准（做到这些才算 done）

- [x] `flutter analyze` 输出 `No issues found!`
- [x] 服务端：save-versions 159、concurrency 28、sync-offline 473（Web；App 475）、
      sync-live 9、admin-baseline 21 全过；cloud-saves 117 部署后经 nginx 跑通
- [x] Web/App 游戏内存档面板统一「上传本机」入口（按钮提到游戏页面板标题栏，
      走合并上传；2026-10-26 13:42 静态已部署并 9/9 一致）
- [x] 客户端：windows-update-result 38、desktop-channels 21、local-server 42、storage-migration 63、game-host-contract 94、
      update-manifest 32、check_cloud_saves 9（离线）、local-save-guard 65 全过；
      desktop-zip 11 用文档 fixture 生成后复跑通过
- [x] B-65：iOS/OHOS 宿主内联 `__local_save_guard.js`，required 缺失/空白/读取
      失败 fail closed；两端口径与 Dart/Android 一致，源码契约断言 11 条
- [x] Android `:app:testDebugUnitTest --rerun-tasks`：10 个类 / 46 tests / 0 failures
- [x] Web 单标签页（写者资格 pass，游戏在顶层文档）：sync-offline [80]/[83]/[86]/[95]；
      第二个标签页不 boot、提示层可见、存档键写入被吞
- [x] 删除启动器在线游玩模式；旧 `playMode:"online"`/`desktopOnlinePort` 迁移断言通过
- [x] Android `:app:testDebugUnitTest` 全绿（含新增 `OnlineGameResourceClientTest` 3 项）
- [x] `tools/test-cloud-saves.sh` 部署后本机跑通（第八轮 117/0/0，经 nginx --resolve）
- [x] Web 测试账号 E2E（临时 `zz-e2e-20261025`，测试后清理）：多玩家 ID 回填、
      手动上传后自动上传无冲突、运行时冲突面板「用云端」、启动冲突页双向、
      账号切换不串档
- [x] Android 测试账号 E2E：原生登录、Saves 页两玩家与 Account ID、版本来源切换、
      单玩家历史与回滚
- [ ] 真实 `akadmin` 的冲突选择/合并（真实数据，留给用户操作）
- [ ] Android 在线游戏真机复测（B-33；模拟器 3 GB 首屏 ANR）
- [ ] 真实账号下一次登录后检查 `saves/<user>/identity.json`；旧 App 令牌需重新登录
- [x] 服务端与静态部署（2026-10-25 22:51 / 23:13 / 23:23）：容器重启加载新
      server.py、`deploy-static.sh --check` 全 ok
- [x] 静态文件最终部署（2026-10-26 04:03）：sync/app-sync/ui/app-ui/admin/
      app-admin/conflict 全部一致；`deploy-static.sh --check` 9 项 ok
- [x] 09:25 的 server.py 已重启加载并冒烟；本轮新 server.py `5b5bf221…`
      （/load 同锁、restoredProfileEvents、tombstone 不截断）已于 2026-10-26
      10:10:45 重启加载；生产 expectedUid 403/正常写入、真实 akadmin /load、
      连续 A/B 回滚事件通过；第八轮静态 10:57 部署后 cloud-saves 117 通过
- [x] 第八轮 8 条 P1 + P2-1 修复项已逐条补真实断言（sync-offline 339、
      guard 65、admin 21、cloud 117）；剩余 B-53 记录在 `07-backlog`
- [x] nginx 两处 location 已补 `X-Authentik-Uid` 并 reload（2026-10-25 22:55）；
      `nginx -t` 通过，Bearer 通道仍显式清空 uid
- [x] 2026-10-26 第八轮：按用户要求**不再调用 oracle-sol**，由 orchestrator
      逐段手工复核 9 条 P1 + P2-1；8 条 P1 与 P2-1 已修并补断言，剩余 B-53
      （Web 多标签页互斥）明确保留为已知 P1
- [x] 静态文件第八轮部署（2026-10-26 10:57 / 11:04）：sync/app-sync/ui/app-ui/admin/
      app-admin/conflict 全部一致；`deploy-static.sh --check` 9 项 ok；
      cloud-saves 117/0/0
- [ ] oracle-sol 对第八轮修复做最终复核（用户另行决定；本轮未调用）
- [x] 2026-10-26 第九轮按用户要求删除启动器在线游玩模式、保留本地游玩；
      云存档/登录/资源下载/更新检查仍可用
- [x] 从最终代码重建 APK `0.9.0-hlh.25`（versionCode 90025，v1/v2/v3 三签）与
      Windows x64 zip；已发布到服务端分发目录并建 `v0.9.0-hlh.25` Release
- [ ] Android 本地资源包真机首屏/退出复测（B-33；模拟器 3 GB 仍 ANR）
- [x] APK/Windows 重新打包前确认 `/_save/app-sync.js` 已包含 `baseProfileVer`
- [x] `bash tools/handoff.sh verify` 22 通过 / 0 失败，seal 已重新生成（15 个文件）

> 真机/Windows 首次更新后的实际点击仍由用户执行；清单在
> `docs/acceptance-android.md`，日志回传后按事件名定位。


## 5. 关键约束（踩过坑，别重复）

1. **服务器地址只走环境变量**：构建时 `--dart-define=PVZGE_SERVER=$PVZGE_SERVER`，
   或 CI secret `PVZGE_SERVER`；本地可放 `.env.local`（0600、已 gitignore）。
   仓库里搜不到 `greatbox` 是硬性验收项。
2. **Windows 构建必须在那台机器上做**（`ssh win`，默认 shell 是 cmd.exe）。本机能做的是
   `flutter analyze`、Dart 验收脚本、Android 构建。细节见 `docs/04-build.md`。
3. **删 `build/` 时一定要连 `.dart_tool/` 一起删**，否则 Windows 报
   `INSTALL.vcxproj MSB3073`（真实原因：`build/native_assets/windows` 缺失）。
4. **解压不能整包读内存**：桌面导入走 `lib/src/services/streaming_zip.dart`，
   不要改回 `package:archive`（1.31 GB 包峰值内存会从 294 MB 涨到 1600 MB）。
5. **越界 ZIP 条目跳过而不是中止**，且**永远不写穿目标目录**（zip-slip）。
6. **启动/迁移/导入/切形态必须互斥**：`_gameLaunchInFlight`、`_storageBusy`、`isImporting`、
   `_desktopGameActive` 四个门禁，新增入口前先看 `app_controller.dart` 的既有判定。
7. **安卓侧不能靠 Dart 定时器做在线会话**：`MainActivity` 拉起 `GameActivity` 后会 `finish()`，
   Flutter 引擎销毁。心跳在 `OnlineSessionHeartbeat.kt`，且 `stop()` 只能异步发请求（主线程 ANR）。
8. **nginx 上凡「后端自己认身份」的 location，必须清空 `X-Authentik-*`**，否则公网可伪造管理员。

## 6. 必读顺序

> 想要「一条提示词进入状态」：直接读 `prompts/04-resume.md`（当前版本的事实快照、
> 刚做完什么、待办、硬约束，可直接整段复制给新会话）。

1. `PROTOCOL.md` —— 契约、状态机、回执字段（5 分钟）
2. `AGENTS.md`（仓库根）：开发范式 + **如何查明状态/判断进度/判断待完成**的方法论
3. 本文档（你在读）
4. `docs/01-architecture.md` —— 客户端双形态 + 服务端数据流
5. `docs/02-branches.md` —— 三个远端的关系与推送规则
6. `docs/03-versioning.md` —— `-hlh.N` 规则、发版四步
7. `docs/04-build.md` —— 本机 vs Windows 主机分别做什么
8. `docs/05-deployment.md` —— 服务端组件、容器、nginx 路由
9. `docs/06-testing.md` —— 测试基线怎么跑、卡住了怎么排查
10. `docs/07-backlog.md` —— 已知缺陷与待决策项（这就是你的工作清单）
11. `docs/08-handoff-log.md` —— 历次接力的回执存档

## 7. 开工动作

```bash
bash tools/handoff.sh status      # 看当前任务与状态
bash tools/handoff.sh verify      # 确认交接包完整（应为 0 失败）
flutter analyze                   # 确认基线干净
```

新会话初始化（不想读长文时）：把 `prompts/04-resume.md` 里 8< 之间的内容整段发过去。
它包含当前版本、产物哈希、基线、刚完成的两件事、待办与硬约束。

然后按 `PROTOCOL.md` 第 2 节：把 `state.json` 的 `task.status` 改成 `accepted` 并写第一条回执
（**必须包含语义回读**：任务标题、当前版本号、测试基线数字），再开始改代码。
