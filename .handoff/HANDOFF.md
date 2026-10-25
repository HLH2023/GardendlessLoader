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

## 2. 当前状态（截至 hlh.23）

- **版本** `0.9.0-hlh.23+90023`，已发布：APK 58,634,998 B（`8e6858b6…`）、
  Windows x64 zip 190,024,520 B（`66a10648…`），Release 在 `private` 仓
  （`v0.9.0-hlh.23`）。APK 与 Windows 更新清单均已发布到服务端分发目录。
- **服务端** `pvzge-server` main `26540fc`：Web 存档版本分区、冲突页下载、
  管理页手动上传版本、静态部署脚本；静态文件已用 `deploy-static.sh` 落地。
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
| 在线游玩（服务端代理 + Bearer） | ✅（无真机验证） | ✅ |
| 云存档（按游戏版本分区、向下兼容） | ✅ | ✅ |
| 资源包管理（安装/切换/删除/改路径/迁移） | ✅ | ✅ |
| 本地 ZIP 导入 | ✅ 原生 | ✅ **自写流式解压** |
| 启动器内登录 | ✅ 原生登录页 | ✅ 浏览器签发 + 粘贴令牌 |
| 自动更新 | ✅ 下载 APK 安装 | ✅ 检查/下载/校验/退出并自动替换（失败回滚） |

- **测试基线 392 项全绿**：服务端 201（97+19+41+44）+ 客户端 191（43+63+11+47+27）。
  另有真实 1.31 GB 资源包压力用例（`tool/stress_real_pack.dart`）：8240 文件 / 6.9 s / 峰值内存 294 MB。
- `flutter analyze` 无告警；APK v1+v2+v3 三签。
- **安全边界**：游戏页面只持有 3 小时存档会话令牌；设备令牌留在原生/本地服务器侧
  （`__sync_native_token`，0600）。历史存档每个（用户/版本/键）保留 300 份，从最旧删起。

## 3. 这次要做什么（任务 R-20261025-02）

标题：**hlh.23：存档面板 Web/Windows/Android 修复**

> 交付状态：已修复并发布（`v0.9.0-hlh.23`）。用户真机复核清单见
> `docs/acceptance-android.md` 3.9/3.10；首次 Windows 自动更新由用户点一次。

按优先级：

1. **P0 — Web 存档管理不可用**。根因是静态文件漂移 + Web 端拿不到游戏版本
   （nginx 先跑 sync.js、后 defer version-check.js）。已修：sync 从页面标题兜底版本；
   冲突页按 gameVersion 读写并支持下载云端 JSON；管理页手动上传写当前版本；
   普通用户可见「存档」面板；删除独立「↑ 上传」按钮。
2. **P0 — Android 游戏内面板按钮全死 / 面板空白**。根因是原生触控适配器在
   document 捕获阶段 preventDefault 掉 click，以及 App iframe 用相对地址落到
   本地资源服务器 404。已修：`data-pvz-ui` 放行 + window 捕获保护；iframe 用
   `cfg.base` 绝对地址。
3. **P1 — Windows 同步**：面板 iframe 绝对地址、同一份 Web 管理页；Windows 首次
   自动更新后验证面板有内容、按钮可点。
4. **P2 — 版本 `0.9.0-hlh.23+90023`，双端构建、服务端静态部署与 Release**（已完成）。

**不做**：改上游分支、把服务器地址/令牌写进仓库、重启 core / 动 frpc(.157) /
动路由(.41)、安卓真机测试本身（用户执行）。

## 4. 验收标准（做到这些才算 done）

- [x] `flutter analyze` 输出 `No issues found!`
- [x] 基线 364 → 392 项；实测 392 通过 / 0 失败（服务端 201 + 客户端 191）
- [x] 每个 P0/P1 缺陷在 `08-handoff-log.md` 里有「现象 → 根因 → 改法 → 断言」四段
- [x] `bash tools/handoff.sh verify` 0 失败（22 通过 / 0 失败 / 0 警告）
- [x] 版本号、`pubspec.yaml`、`state.json` 的 `release` 三者一致（0.9.0-hlh.23 + 90023）
- [x] 产物：APK 三签通过 + sha256；Windows zip sha256（`ssh win` 构建，已回传核对）
- [x] 没有把任何服务器地址/令牌写进受版本控制的文件（verify 源码扫描通过）
- [x] 服务端静态文件由 `tools/deploy-static.sh` 生成/部署；`--check` 与测试套件均通过

> 仍未闭环的是**真机/Windows 首次更新后的实际点击**——按约定由用户执行；清单在
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

然后按 `PROTOCOL.md` 第 2 节：把 `state.json` 的 `task.status` 改成 `accepted` 并写第一条回执
（**必须包含语义回读**：任务标题、当前版本号、测试基线数字），再开始改代码。
