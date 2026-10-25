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

## 2. 当前状态（截至 hlh.16）

- **版本** `0.9.0-hlh.16+90016`，已发布：APK 58,601,809 B（`e8fceb2a…`）、
  Windows x64 zip 190,057,219 B（`d75821d9…`），Release 在 `private` 仓。
- **能力矩阵**

| 能力 | Android | Windows |
|---|---|---|
| 本地离线游玩（资源包在本地） | ✅ | ✅（本轮打通） |
| 在线游玩（服务端代理 + Bearer） | ✅（无真机验证） | ✅ |
| 云存档（按游戏版本分区、向下兼容） | ✅ | ✅ |
| 资源包管理（安装/切换/删除/改路径/迁移） | ✅ | ✅ |
| 本地 ZIP 导入 | ✅ 原生 | ✅ **自写流式解压** |
| 启动器内登录 | ✅ 原生登录页 | ✅ 浏览器签发 + 粘贴令牌 |
| 自动更新 | ✅ 下载 APK 安装 | 手动替换（Windows 不做自更新） |

- **测试基线 251 项全绿**：服务端 142（55+19+27+41）+ 客户端 109（43+55+11）。
  另有真实 1.31 GB 资源包压力用例（`tool/stress_real_pack.dart`）：8240 文件 / 6.9 s / 峰值内存 294 MB。
- `flutter analyze` 无告警；APK v1+v2+v3 三签。

## 3. 这次要做什么（任务 R-20261025-01）

标题：**hlh.17：安卓端到端验收 + 资源包管理 UI 收口 + 已知缺陷清零**

按优先级：

1. **P0 — 安卓真机验收配合**。用户在真机上跑；你负责：
   - 产出一份「点哪几步、看什么、失败时抓什么日志」的验收清单，写进 `docs/acceptance-android.md`
     （新建，别塞进 `docs/acceptance-checklist.md`——那是上游文件）。
   - 针对在线形态重点验证：心跳是否真的登记（服务端 `online/status` 应 >0）、401 后是否会退登、
     切后台再回来资源是否继续加载。
   - 用户贴回来的日志要能直接定位到代码位置；定位不了就补日志埋点，别靠猜。
2. **P0 — `docs/07-backlog.md` 里的 P0/P1 逐条修**。每条修完必须补一个可跑的断言（放进现有
   4 个服务端 / 3 个客户端套件，不要新建框架）。
3. **P1 — 资源包管理 UI 双端一致性**：Windows 与安卓的安装列表/切换/删除/改路径/迁移，
   文案、状态反馈、失败提示要一致；不一致的地方以「用户能看懂 + 不会误操作」为准改。
4. **P2 — 版本升到 `0.9.0-hlh.17`，双端构建并发布**（发布动作由 Hermes 复核，你负责把版本号、
   CHANGELOG 条目、构建脚本跑通并给出产物哈希）。

**不做**：改上游分支、把服务器地址写进仓库、重启 core / 动 frpc(.157) / 动路由(.41)、
安卓真机测试本身（用户执行）。

## 4. 验收标准（做到这些才算 done）

- [ ] `flutter analyze` 输出 `No issues found!`
- [ ] 251 项基线不减少，新增修复各自带断言（给出新的总数）
- [ ] 每个 P0/P1 缺陷在 `08-handoff-log.md` 里有「现象 → 根因 → 改法 → 断言」四段
- [ ] `bash tools/handoff.sh verify` 0 失败
- [ ] 版本号、`pubspec.yaml`、`state.json` 的 `release` 三者一致
- [ ] 产物：APK 三签通过 + sha256；Windows zip sha256（本机构建或 `ssh win` 构建）
- [ ] 没有把任何服务器地址/令牌写进受版本控制的文件

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
2. 本文档（你在读）
3. `docs/01-architecture.md` —— 客户端双形态 + 服务端数据流
4. `docs/02-branches.md` —— 三个远端的关系与推送规则
5. `docs/03-versioning.md` —— `-hlh.N` 规则、发版四步
6. `docs/04-build.md` —— 本机 vs Windows 主机分别做什么
7. `docs/05-deployment.md` —— 服务端组件、容器、nginx 路由
8. `docs/06-testing.md` —— 251 项怎么跑、卡住了怎么排查
9. `docs/07-backlog.md` —— 已知缺陷与待决策项（这就是你的工作清单）
10. `docs/08-handoff-log.md` —— 历次接力的回执存档

## 7. 开工动作

```bash
bash tools/handoff.sh status      # 看当前任务与状态
bash tools/handoff.sh verify      # 确认交接包完整（应为 0 失败）
flutter analyze                   # 确认基线干净
```

然后按 `PROTOCOL.md` 第 2 节：把 `state.json` 的 `task.status` 改成 `accepted` 并写第一条回执
（**必须包含语义回读**：任务标题、当前版本号、测试基线数字），再开始改代码。
