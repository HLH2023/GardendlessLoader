# 04 构建：本机 vs Windows 主机

## 1. 谁在哪做（先看这张表）

| 工作 | 本机（Linux, NBPC） | Windows 主机（`ssh win`） | CI |
|---|---|---|---|
| `flutter analyze` / `dart run tool/*.dart` | ✅ | 可选 | ✅ |
| 服务端测试（4 套 142 项） | ✅ | — | — |
| Android APK 构建 | ✅ | — | — |
| **Windows exe 构建** | ❌ 不能交叉编译 | ✅ 必须 | ✅ `windows-latest` |
| 服务端部署（容器/nginx/资源包） | ✅ Hermes 执行 | — | — |
| 安卓真机安装与验收 | 用户执行 | — | — |

## 2. 本机工具链（已装好）

```
Flutter    3.41.9   /home/hlh/flutter        (Dart 3.11.5)
JDK        17       /home/hlh/jdk17          (Temurin；系统 java 21 只有 JRE，别用)
Android SDK 36      /home/hlh/Android/Sdk    build-tools 36.0.0
```

```bash
export PATH=/home/hlh/flutter/bin:$PATH
flutter analyze
bash tools/build-apk.sh --release        # 产物 build/app/outputs/flutter-apk/app-release.apk
```

⚠️ Gradle 会被 Hermes 的 4 GiB cgroup 杀掉 → 必须用 `systemd-run -p MemoryMax=8G`（见 `03-versioning.md`）。

## 3. Windows 主机

```
ssh win            → 别名已在 ~/.ssh/config 配好，默认 shell 是 cmd.exe
源码目录           C:\Users\s2681\GardendlessLoader-src
运行目录           C:\Users\s2681\GardendlessLoader
Flutter            C:\src\flutter (3.41.9)
VS2022 Community   D 盘，含 Desktop C++（flutter doctor 全绿）
```

### 3.1 同步源码

```bash
tar czf /tmp/gl-src.tgz lib tool pubspec.yaml pubspec.lock
scp -q /tmp/gl-src.tgz win:C:/Users/s2681/
ssh win "powershell -NoProfile -Command \"Set-Location 'C:\Users\s2681\GardendlessLoader-src'; tar xzf C:\Users\s2681\gl-src.tgz\""
```

### 3.2 构建

```bash
# 方式 A：把命令写成 .ps1 再执行（推荐，避免 cmd/powershell 引号地狱）
scp -q tools/build-windows.ps1 win:C:/Users/s2681/build-windows.ps1   # 注意：脚本需 UTF-8 BOM + CRLF
ssh win "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\s2681\build-windows.ps1 -Server <SERVER>"

# 方式 B：直接调仓库里的脚本（源码已同步时）
ssh win "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\s2681\GardendlessLoader-src\tools\build-windows.ps1 -Server <SERVER>"
```

产物：`dist\gardendless-loader-<version>-<code>-windows-x64.zip` + `.sha256`（约 181 MB 压缩 / 417 MB 解压）。

### 3.3 三个必踩的坑

1. **PowerShell 5.1 读中文注释会崩**：`.ps1` 必须存成 `utf-8-sig` + CRLF，否则报语法错误。
2. **`ssh win "a; b"` 不执行**：默认 shell 是 cmd.exe，多条命令要 `powershell -NoProfile -Command "..."`，
   或者干脆写成 `.ps1` 用 `-File` 跑。
3. **删 `build/` 必须同时删 `.dart_tool/`**：否则 CMake INSTALL 报 `MSB3073`，真实错误是
   `file INSTALL cannot find build/native_assets/windows`。清干净后 `flutter pub get` 再来一遍。

### 3.4 CEF 说明

Windows 端 WebView 用 `webview_cef 0.6.2`（自带 Chromium，不依赖用户 Edge 版本）。
`webview_flutter_windows 1.3.0` 要求 Dart ≥3.12、`webview_windows 0.4.0` 锁 sdk <3.0，都不适配当前 Flutter。
所以包体大（`libcef.dll` 占 270 MB）是正常的。

## 4. GitHub Actions

`.github/workflows/build-windows.yml`：`windows-latest` 自带 VS2022 + Desktop C++，
`pub get → analyze → build → Compress-Archive + sha256 → artifact`，tag 构建自动挂 Release。
服务器地址通过仓库 secret `PVZGE_SERVER` 注入，**不要写进 workflow 文件**。

```bash
gh workflow run build-windows.yml --repo HLH2023/gardendless-app --ref main
```

## 5. 本机验收脚本（不需要设备）

```bash
dart run tool/check_local_server.dart          # 43 项：本地服务器
dart run tool/check_storage_migration.dart     # 62 项：存储迁移 + 日志自愈 + 空间预检 + 事务门禁
dart run tool/check_desktop_zip.dart <zip>     # 11 项：流式解压 + zip-slip
dart run tool/check_game_host_contract.dart    # 25 项：原生退出原因契约 + 令牌失效退登判定
dart run tool/stress_real_pack.dart <big.zip> <targetDir>   # 真实 1.3 GB 包：内存/计数
```
