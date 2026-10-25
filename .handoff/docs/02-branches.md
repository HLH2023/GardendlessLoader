# 02 分支与远端

## 1. 三个远端

```bash
git remote -v
# upstream  Dey410/GardendlessLoader     ← 作者主线，只读
# origin    HLH2023/GardendlessLoader     ← 公开 fork（我们的长期工作分支 feature/app-update）
# private   HLH2023/gardendless-app       ← 私有仓（代码镜像 + Release 资产）
```

| 远端 | 分支 | 能不能推 | 说明 |
|---|---|---|---|
| `upstream` | `main` | ❌ **绝对不推** | 只 `git fetch upstream` 看作者更新；不提 PR |
| `origin` | `feature/app-update` | ✅ 推这里 | 日常开发的唯一目标分支，`main` 保持上游状态 |
| `private` | `main` | ✅ 推这里 | 代码镜像（含不便公开的部分）+ 发布 APK/Windows zip 的 Release |

服务端源码是**另一个仓库**：`HLH2023/pvzge-server`（私有，`main`），本地路径 `/home/hlh/pvzge`。

## 2. 日常提交

```bash
git add -A
git commit -m "Type: 一句话说清做了什么"
git push origin HEAD:refs/heads/feature/app-update
git push private HEAD:refs/heads/main
```

提交信息风格沿用上游：`Fix:` / `Update:` / `Modify:` / `Add:` + 祈使句摘要；
个人构建线可以用 `hlh.N: 主题` 开头，正文列「改了什么 / 为什么 / 怎么验证」。

## 3. 跟上游同步

```bash
git fetch upstream
git log --oneline HEAD..upstream/main      # 看上游新增了什么
git merge upstream/main                    # 或 cherry-pick
```

冲突高发区：`lib/src/app_controller.dart`、`lib/src/ui/home_page.dart`、`AGENTS.md`、`pubspec.yaml`。
合并后必须重跑：`flutter analyze` + 251 项测试 + 受影响的平台构建。

## 4. 为什么要有 private 仓

1. Release 资产（APK / Windows zip）需要一个**私有**的可下载位置；公开 fork 不放产物。
2. 个人构建线的完整历史（含内部文档、脚本）放私有仓，公开 fork 保持可分享状态。
3. 发版：`gh release create ... --repo HLH2023/gardendless-app`，资产名用
   `gardendless-loader-<version>.apk` 与 `gardendless-loader-<version>-windows-x64.zip`。
   （`gh release create` 不支持 `#重命名`，要么先改名再上传，要么 `delete-asset` 后按正确名 `upload`。）

## 5. 分支命名

- `feature/app-update` — 当前主工作分支（自动更新 + 双端 + 云存档）
- 历史：`feature/app-login`、`feature/cloud-saves`（已合入或废弃，别再往上面加东西）
- 新功能分支：`feature/<短横线主题>`，从 `feature/app-update` 切出，合回同一个分支
