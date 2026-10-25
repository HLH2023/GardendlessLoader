# 01 架构

## 1. 一句话结构

Flutter 启动器（状态/资源/存档/设置） → 原生游戏宿主（Android WebView / Windows CEF） → 游戏本体（本地文件或服务端反代）。

## 2. 目录与职责（`lib/src/`）

| 位置 | 职责 |
|---|---|
| `app_controller.dart` | 唯一的编排层：初始化、资源导入、游玩形态、存档桥、更新检查、日志。**改行为先看这里** |
| `services/import_service.dart` | 资源导入事务：`beginImport → completeImport/abortImport`，双槽（slot A/B）切换，崩溃可恢复 |
| `services/resource_validator.dart` | 资源包校验（入口文件、包名、版本、体积） |
| `services/streaming_zip.dart` | **自写流式 ZIP 读取**（桌面导入用）：中央目录 + ZIP64 + stored/deflate 分块，1 MB 块恒定内存 |
| `services/desktop_zip_extractor.dart` | 桌面导入门面：zip-slip 跳过计数、进度回调 |
| `services/resource_picker_service.dart` | 平台分流：Android 走原生 MethodChannel，Windows/Linux/macOS 走 Dart 解压 |
| `services/local_resource_server.dart` | 桌面端本地 HTTP 服务器：服务资源目录 / 反代上游 / 注入桥脚本 / Range+MIME / 路径与符号链接防护 |
| `services/storage_migration.dart` | 改存储位置：条目搬迁、跨盘 copy+校验+删、回滚、**迁移日志 + 启动自愈 + 空间预检** |
| `services/app_settings_store.dart` | 设置与 `PlayMode { local, online }`，设备令牌也在这里（文件 0600） |
| `services/cloud_save_service.dart` / `remote_resource_service.dart` | 云存档 / 远端资源清单的 HTTP 客户端（Bearer） |
| `ui/pages/desktop_game_page.dart` | Windows CEF 游戏窗口，退出用 try/finally 保证停服 |
| `ui/pages/storage_location_card.dart` | 存储位置 UI（Android 用候选目录，避开 SAF `content://`） |
| `game_host/` | `GameSession` 契约 + 平台通道（`mode` / `originOverride` / `appRoot` / `gameVersion`） |

Android 原生：`android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/`
- `GameActivity.kt` — WebView 宿主、手势、导出、退出
- `GameSessionCodec.kt` — 会话参数编解码（含 `mode=local|online`）
- `OnlineGameResourceClient.kt` — 在线形态带 Bearer 代理子资源 + 注入存档桥
- `OnlineSessionHeartbeat.kt` — **原生 60 s 心跳**（Dart 定时器活不过引擎销毁）

## 3. 两种游玩形态

| | local（离线） | online（在线） |
|---|---|---|
| 资源来源 | 本地资源包目录 | 服务端 `/_save/online/` 反代 |
| Android 实现 | WebView 直读本地文件 | `OnlineGameResourceClient` 带 Bearer 抓子资源 |
| Windows 实现 | `LocalResourceServer` 读磁盘 | `LocalResourceServer` 反代上游并**移除服务端脚本**后再注入本地桥 |
| 存档桥 | 本地生成的 `app-sync.js` | 同一份桥（origin 都是 `127.0.0.1`，语义一致） |
| 前提 | 已导入并通过校验 | 已登录（有设备令牌）+ 已配置服务器地址 |

设计要点：**两种形态共用同一个 `LocalResourceServer` 与同一份存档桥**，避免两套存档语义。
Windows 默认 local（用户明确要求「下载资源」而非在线）。

## 4. 云存档数据流

```
游戏 JS  ──(注入的 bridge/sync.js)──▶  服务端 /_save/app/{load,save}
   │                                        │
   └─ localStorage(save keys)               └─ saves/<user>/by-version/<gameVersion>/<key>.json
                                                    │
                                                    └─ 历史快照 ts-n、restored 标记、ver 纳秒版本号
```

- **按游戏版本分区**：`1.6.1` 与 `1.6.2` 各一套目录，互不覆盖。
- **向下兼容**：新版本首次进入若无本版存档，读旧版并标记 `load_kind=migrated`，随后按新版重传；
  只有「更新的版本有档」时才拒绝降级读（`version_mismatch`）并停止上传。
- **并发**：`fcntl.flock` + 纳秒版本号乐观并发（`baseVer`），冲突返回 `stale_base`。
- **空档保护**：不允许用空存档覆盖非空存档。
- `sync.js` 的并发基准（`__pvzCloudVer`）**绑定游戏版本**，切版本后旧基准作废。

## 5. 资源包（本地形态）

- 服务端产出 `/var/www/pvzge-res/pvzge-res-<gameVersion>.zip`（约 1.3 GB / 8000+ 文件 / ZIP_STORED）。
- 客户端下载或用户自选 ZIP → 解压到候选槽 → 校验 → 原子切换 `activeSlot` → 旧槽清理。
- 只保留一份最新可用资源；切换/删除/迁移都在 `app_controller` 的状态门禁下进行。

## 6. 状态门禁（改任何入口前必读）

| 门禁 | 含义 |
|---|---|
| `_gameLaunchInFlight` | 正在启动游戏（Android `startGame` 与桌面 `prepareDesktopGame` 都要置位） |
| `_desktopGameActive` | 桌面游戏窗口在跑（服务器已起） |
| `_storageBusy` | 正在迁移存储 |
| `isImporting` | 正在导入/校验资源 |
| `manifest.transactionState` | 导入事务持久态（`extracting/validating/selfChecking/readyToActivate`），启动时按它恢复 |

规则：**任何一个破坏性入口（启动/导入/迁移/切形态/删除资源）都必须同时检查这四个内存门禁，
并把持久态 `transactionState` 作为崩溃恢复依据。**
