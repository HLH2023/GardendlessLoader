# Repository Guidelines

## Project Structure & Module Organization

- `lib/main.dart` starts the app.
- `lib/src/app_controller.dart` coordinates state, imports, native GameHost launch, announcements, and update checks.
- `lib/src/services/` holds resource validation, ZIP import, manifest storage, diagnostics, and filesystem self-checks.
- `lib/src/game_host/` defines the durable native GameSession and platform-channel launch contract.
- `lib/src/ui/` contains the Flutter launcher screen in `home_page.dart`.
- `assets/game_bridge/` contains the shared document-start scripts injected by every native GameHost.
- Maintained platform folders are `android/`, `ios/`, and `ohos/`.
- `announcements.json` is the remote announcement payload; `docs/acceptance-checklist.md` records manual release checks.
- `docs/research/native_gamehost_local_resource_loading.md` records the native GameHost security constraints and device-validation limits.

## Build, Test, and Development Commands

- `flutter pub get` installs Dart and Flutter dependencies.
- `flutter analyze` runs static analysis with the repository lint rules.
- `flutter run` starts the app on a connected supported device.
- `flutter build apk --release` builds Android.
- `flutter build ios --release --no-codesign` builds unsigned iOS artifacts.

For HarmonyOS/OpenHarmony, copy `pubspec_overrides.ohos.yaml` to `pubspec_overrides.yaml`, use the OpenHarmony Flutter SDK, and follow `README.md`.

## Coding Style & Naming Conventions

This project uses `package:flutter_lints/flutter.yaml` plus `prefer_single_quotes`. Use two-space Dart indentation, `UpperCamelCase` for classes/widgets, `lowerCamelCase` for methods and variables, and `snake_case.dart` filenames. Keep service logic in `lib/src/services/` and UI code in `lib/src/ui/`. Run `dart format lib` before submitting.

## Validation Guidelines

The Flutter unit and widget test suite was removed at the user's request. Do not recreate per-feature Flutter test files automatically. Validate Dart changes with `flutter analyze`, build the affected maintained platforms, and verify relevant workflows on devices. Existing native and shared JavaScript checks remain available.

## Commit & Pull Request Guidelines

Recent history uses short prefixes such as `Fix:`, `Update:`, and `Modify:`. Follow `Type: concise imperative summary`, for example `Fix: handle nested docs imports`. PRs should describe the change, list tested commands, link issues when applicable, and include screenshots or recordings for UI changes.

## Security & Configuration Tips

Do not commit bundled game resources, signing files, generated archives, or `.DS_Store` files. Keep Android signing values in CI secrets. Preserve active-slot path confinement and non-allowlisted WebView request blocking.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Domain docs

This repository uses a single-context domain documentation layout. See `docs/agents/domain.md`.

## Agent 接力（Hermes ⇄ OpenChamber）— 先读这一节

本仓库有一条**个人构建线**（版本号以 `-hlh.N` 结尾），由 Hermes 与 OpenChamber 开发 agent
接力推进。任何接手的 agent 在动代码之前必须：

1. 读 `.handoff/HANDOFF.md`（交接主文档：当前状态 + 本次任务 + 验收标准）
2. 读 `.handoff/PROTOCOL.md`（契约：状态机、回执必填字段、红线）
3. 跑 `bash tools/handoff.sh status && bash tools/handoff.sh verify`（必须 0 失败）
4. 需要细节再按 `HANDOFF.md` 第 6 节的顺序读 `.handoff/docs/01..08`

摘要（详见上述文件）：

- **分支**：`upstream`(Dey410) 只读，**不推不改不提 PR**；开发推 `origin:feature/app-update`；
  产物与镜像推 `private:main`。
- **版本**：`versionName = X.Y.Z-hlh.N`，`versionCode = major*1e6 + minor*1e4 + patch*100 + N`。
- **构建边界**：`flutter analyze`、`dart run tool/*.dart`、服务端测试、Android APK 在本机；
  **Windows exe 只能在 Windows 主机上构建**（`ssh win`）。
- **安全红线**：个人服务器地址与令牌**绝不写进任何受版本控制的文件**，只用 `PVZGE_SERVER`
  环境变量 / CI secret / `.env.local`(0600, gitignored)。
- **改动前先看既有机制**：启动/迁移/导入互斥、`streaming_zip.dart`、`local_resource_server.dart`、
  `OnlineSessionHeartbeat.kt` 都已有实现与断言，别重造。
- **交付**：按 `PROTOCOL.md` 第 3 节写回执（真实命令输出 + 真实测试数字 + 产物 sha256），
  跑 `bash tools/handoff.sh verify` 到 0 失败。

改完代码后请补上一次性小提示：本仓库的 Flutter 单元/组件测试套件是**故意移除**的（见下文
Validation Guidelines），不要把新增逻辑写成 `test/` 下的 widget test；改为加进
`tool/check_*.dart` 或服务端 `tools/test-*.sh`。
