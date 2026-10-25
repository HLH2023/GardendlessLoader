---
name: gardendless-dev
description: Use when working in the GardendlessLoader repository (personal build line, versions ending -hlh.N) on any Dart/Kotlin/JS/Python change, resource-pack or save-api work, or when resuming a handoff from Hermes. Carries the branch/version/build/deployment rules, the state-gate invariants, and the handoff protocol that must be followed before touching code.
---

# GardendlessLoader 开发技能（个人构建线）

## 0. 开工三十秒

```bash
bash tools/handoff.sh status     # 当前任务、版本、状态
bash tools/handoff.sh verify     # 交接包是否完整（必须 0 失败）
flutter analyze                  # 基线必须干净
cd /home/hlh/pvzge && bash tools/test-cloud-saves.sh | tail -1   # 服务端基线（可选）
```

状态在 `.handoff/state.json`，契约在 `.handoff/PROTOCOL.md`。**先读 `.handoff/HANDOFF.md` 再做任何事。**

## 1. 三条硬红线

1. **个人服务器地址与令牌绝不进受版本控制的文件。** 用 `PVZGE_SERVER` 环境变量 / CI secret /
   `.env.local`（0600，已 gitignore）。提交前自查：`grep -rn greatbox . --exclude-dir=.git` 必须无输出。
2. **`upstream`(Dey410) 只读**：不推、不改、不提 PR。开发推 `origin:feature/app-update` 与 `private:main`。
3. **运维副作用动作不自己做**：容器重建、nginx 重载、资源包重打包、发 Release、重启宿主 →
   写进回执的 `needsHermes`，由 Hermes 执行。

## 2. 版本号

```
versionName = X.Y.Z-hlh.N ;  versionCode = major*1e6 + minor*1e4 + patch*100 + N
0.9.0-hlh.17 → 90017
```
`bash tools/bump-version.sh` 自动 +1；**必须在 `build-apk.sh` 之前**。四处必须一致：
`pubspec.yaml` / `state.json.release` / Release tag / 产物文件名。

## 3. 构建边界

| 能本机做 | 必须 Windows 主机（`ssh win`） |
|---|---|
| `flutter analyze`、`dart run tool/*.dart`、服务端 4 套测试、Android APK | Windows exe（不可交叉编译） |

本机工具链：Flutter `/home/hlh/flutter`、JDK17 `/home/hlh/jdk17`、SDK `/home/hlh/Android/Sdk`。
Gradle 会被 4 GiB cgroup 杀 → 用 `systemd-run -p MemoryMax=8G`。

Windows：`ssh win`（别名已在 `~/.ssh/config` 配好，默认 cmd.exe）→ 多命令用
`powershell -NoProfile -Command` 或写 `.ps1` 用 `-File`（`.ps1` 必须 `utf-8-sig` + CRLF）。
**删 `build/` 必须连 `.dart_tool/` 一起删**，否则 `INSTALL.vcxproj MSB3073`
（真实原因：`build/native_assets/windows` 缺失）。

## 4. 必须先看的既有机制（别重造）

| 要改的东西 | 先读 |
|---|---|
| 启动/导入/迁移/切形态 | `app_controller.dart` 的 `_gameLaunchInFlight` / `_storageBusy` / `isImporting` / `_desktopGameActive` 四个门禁 |
| 资源导入事务 | `services/import_service.dart`（双槽 + `transactionState` 崩溃恢复） |
| 桌面解压 | `services/streaming_zip.dart`（**不要改回 `package:archive`**：1.31 GB 包峰值内存 1600 MB → 294 MB） |
| 桌面本地服务器 | `services/local_resource_server.dart`（注入、Range、路径+软链防护） |
| 存储迁移 | `services/storage_migration.dart`（迁移日志 + 启动自愈 + 空间预检） |
| 在线形态（安卓） | `OnlineGameResourceClient.kt` + `OnlineSessionHeartbeat.kt`（Dart 定时器活不过引擎销毁） |
| 存档语义 | 服务端 `/home/hlh/pvzge/save-api/{server.py,sync.js}`（按游戏版本分区 + 向下兼容 + 乐观并发） |

## 5. 测试

基线 **251 项**：服务端 142（55/19/27/41）+ 客户端 109（43/55/11）。
新增断言**加进现有套件，不新建框架**。改安全相关逻辑必须同时有正例与反例。
真实资源包压力用例：`dart run tool/stress_real_pack.dart <zip> <dir>`，判据「峰值内存远小于包体」。

## 6. 交接协议（摘要）

- 只按 `PROTOCOL.md` 的状态机走：`dispatched → accepted → in_progress → review`（或 `blocked`）。
- `accepted` 必须带**语义回读**（任务标题、当前版本号、测试基线数字），抄错即未通过。
- 回执写进 `state.json.receipts[]` + `docs/08-handoff-log.md`，数字必须真跑出来，不许写「应该通过」。
- 交付后 `bash tools/handoff.sh verify` 必须 0 失败，输出原样贴进回执。

## 7. 提交

```bash
git add -A && git commit -m "Fix: 一句话说清改了什么"
git push origin HEAD:refs/heads/feature/app-update
git push private HEAD:refs/heads/main
```
提交信息沿用上游风格（`Fix:` / `Update:` / `Modify:` / `Add:`），个人构建线可用 `hlh.N: 主题`。
合上游（`git merge upstream/main`）后必须重跑：`flutter analyze` + 251 项 + 受影响平台构建。

## 8. 遇到这些现象先别改代码

| 现象 | 先怀疑 |
|---|---|
| 测试返回 `501` / `000` | 测试脚本自己的 URL 拼装（`--resolve`、变量未展开） |
| `401` 但令牌看着有效 | 令牌文件被删/过期；或走了需要 authentik 的 location |
| Windows `MSB3073` | `build/` 与 `.dart_tool/` 状态不一致 |
| PowerShell 语法错误 | `.ps1` 缺 UTF-8 BOM / CRLF |
| 迁移用例失败 | 目标盘空间不足（预检会拒绝）或残留 `.pvz-migrating.json` |
