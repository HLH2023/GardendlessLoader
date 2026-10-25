# 03 版本号与发版

## 1. 规则（写死）

```
versionName = X.Y.Z-hlh.N           例：0.9.0-hlh.16
versionCode = major*1e6 + minor*1e4 + patch*100 + N    例：0.9.0-hlh.16 → 90016
```

- `X.Y.Z` 跟随上游主版本语义；`-hlh.N` 是**我们这条个人线**的序号，只增不减。
- `N` 从 1 开始连号，**每次发版必 +1**；不发版不改版本号。
- `pubspec.yaml`、`state.json.release.versionName`、Release tag、产物文件名四者必须一致。

## 2. 升版本

```bash
bash tools/bump-version.sh        # 自动算下一个 hlh.N 并写 pubspec.yaml
```

⚠️ `bump-version.sh` **必须在 `build-apk.sh` 之前**跑，否则 APK 里的版本号是旧的。

## 3. 发版四步

```bash
# 1) 升版本
bash tools/bump-version.sh

# 2) 构建 APK（Hermes 4 GiB cgroup 会杀 Gradle，要抬内存）
systemd-run --user --no-block --collect --unit=gl-hlhNN-build \
  -p MemoryMax=8G -p MemorySwapMax=4G -p Nice=5 \
  --setenv=PATH=/home/hlh/flutter/bin:/usr/local/bin:/usr/bin:/bin \
  --setenv=JAVA_HOME=/home/hlh/jdk17 \
  --setenv=ANDROID_HOME=/home/hlh/Android/Sdk \
  --setenv=ANDROID_SDK_ROOT=/home/hlh/Android/Sdk \
  /bin/bash -lc 'cd /home/hlh/dev/GardendlessLoader && flutter analyze && bash tools/build-apk.sh --release'

# 3) 发布 APK 到服务端分发目录（脚本在服务端仓库）
bash /home/hlh/pvzge/tools/publish-apk.sh build/app/outputs/flutter-apk/app-release.apk \
  --version 0.9.0-hlh.N --notes "本版要点"

# 4) 推代码 + 建 Release
git push origin HEAD:refs/heads/feature/app-update
git push private HEAD:refs/heads/main
gh release create v0.9.0-hlh.N --repo HLH2023/gardendless-app \
  --title "0.9.0-hlh.N — 一句话" --notes "<markdown>" \
  <apk 路径> <windows zip 路径>
```

## 4. 发版后必验（不做等于没发）

```bash
# 签名：三项必须全 true（国产 ROM 只认全签）
$ANDROID_HOME/build-tools/36.0.0/apksigner verify --min-sdk-version 21 -v <apk>
# 产物哈希：本机 vs 公网下载件
sha256sum <apk>
curl -s -o /dev/null -w '%{http_code}\n' -L "$PVZGE_SERVER/_res/apk/gardendless-loader-0.9.0-hlh.N.apk"
# Release 资产名与大小
gh release view v0.9.0-hlh.N --repo HLH2023/gardendless-app --json assets --jq '.assets[] | "\(.name) \(.size)"'
```

## 5. Windows 产物

- 文件名：`gardendless-loader-<version>-<versionCode>-windows-x64.zip`
- 由 `tools/build-windows.ps1` 生成，同时输出 `.sha256`
- 构建机：`ssh win`（见 `04-build.md`），或 GitHub Actions `build-windows.yml`（`windows-latest`，约 14 分钟）
- 发布到客户端更新通道（服务端仓库）：`bash tools/publish-windows.sh <zip> --version 0.9.0-hlh.N`
  → 写 `/var/www/pvzge-res/win/manifest.json`（latest + 最近 3 个历史）与 zip；
  客户端从 `/_save/app/res/win/manifest.json` 读，靠 `versionCode` 判断是否有新版。

## 6. 存档里的版本语义（易混，单列）

游戏版本（如 `1.6.2`）与客户端版本（`0.9.0-hlh.16`）**是两套东西**：
- 客户端版本 → `versionName/versionCode`，决定升级与 APK 覆盖。
- 游戏版本 → 存档分区键（`saves/<user>/by-version/<gameVersion>/`），决定存档能不能通用。
改任一套都不要顺手改另一套。
