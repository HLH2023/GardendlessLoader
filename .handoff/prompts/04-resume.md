# 新会话开工提示词

> 用法：把下面「----- 8< -----」之间的整段复制给新会话即可。
> 这是一份**自包含**的交接：事实以 `.handoff/` 为准，冲突时按 `PROTOCOL.md` 与
> `state.json` 修正本文件（并把修正写回，别让它过期）。

----- 8< -----

你是 GardendlessLoader 个人构建线的接力 agent。工作目录
`/home/hlh/dev/GardendlessLoader`（git 分支 `feature/app-update`）。

## 第一步（不要跳过）

```bash
cd /home/hlh/dev/GardendlessLoader
bash tools/handoff.sh status     # 版本 / 当前任务 / 基线 / 回执数
bash tools/handoff.sh verify     # 必须 0 失败；不通过就先修交接包，别急着改代码
flutter analyze                  # 必须 No issues
cat .handoff/HANDOFF.md          # 主文档：当前状态、任务、验收、约束
```

然后按 `AGENTS.md`（范式与判定方法）→ `.handoff/PROTOCOL.md`（契约）→
`HANDOFF.md` 第 6 节的顺序读 `docs/`。

## 现在的状态（2026-10-28）

- 版本 `0.9.0-hlh.35+90035`，已发布：APK 58,652,226 B（`f2f1f269…`）、
  Windows x64 zip 190,980,540 B（`9c1e5b3a…`）；服务端两份清单 latest=hlh.35；
  GitHub Release `v0.9.0-hlh.35`（私有仓，4 个资产）。
- 测试基线 **1305**（服务端 828 + 客户端 477）。Windows 实机另有
  63（更新脚本，含真实包）+ 13（全屏）+ 5（干净退出），不计入基线。
- 用户实机 `D:\Program Files\gardendless-loader` 已就地升级到 hlh.35
  （10/0；`downloads` 8252 个文件 / 2025.9 MB 前后一致；12 秒冒烟无崩溃），
  用户已实机确认桌面端数字/字母快捷键生效。
- **2026-10-28 只改了服务端静态文件**（B-72，无客户端版本）：桌面端冲突弹窗
  「用云端存档（覆盖本机并重启）」点了没反应——CEF 离屏渲染没有 JS 对话框，
  `confirm()` 恒 false。已改成页面内二次确认（`save-api/ui.js`、`conflict.html`、
  `admin.html` 的 6 个破坏性动作），`tools/deploy-static.sh` 已部署并通过 `--check`。
- 工作树**已提交**：`5ee2aaa`（hlh.25–hlh.35 代码）+ `ab3387a`（交接文档），
  已推 `origin/feature/app-update` 与 `private/main`；服务端仓 `/home/hlh/pvzge`
  提交 `8a5e343` 已推 `pvzge/main`。发版走本地产物 + 服务端分发目录。

## 刚做完的两件事（别重做）

1. **hlh.28 Windows 全屏**（B-70）：原生窗口通道
   `io.github.dey410.gardendlessloader/window` 做 `WS_POPUP` 边框全屏（退出精确
   还原），注入脚本把 DOM 全屏 API 转给宿主并伪造 `document.fullscreenElement`，
   另有 F11 与工具栏按钮；离开游戏页自动退出全屏。
2. **hlh.35 快捷键最终修复**（B-76/B-77，P0）：真机日志证明按键已到页面，
   但 `webview_cef` 的 `native_key_code` 是整条 `lParam`，`event.code` 为空；
   Cocos 按 code 映射热键且监听绑在 `#GameCanvas`。页面捕获阶段用 keyCode
   还原 code 并重派发到画布（原生事件截住、不双份；真实输入框不拦）。
3. **hlh.32 键盘引导时序修复**（B-76，P0）：hlh.30 修好的游戏内快捷键在
   hlh.31 又失效——旧脚本在 `document.body` 出现前就写「已安装」标志，注入
   落在 HTML 解析中时探针被移走、焦点丢失，loadEnd 的二次注入被标志挡掉，
   CEF 的 `current_focused_browser_` 永远为空。现在只有探针真的挂上并聚焦
   成功才算完成，`setClientFocus(true)` 提前，loadEnd 1.2s 后强制补焦一次；
   新增 `keyboard.log`（应用支持目录，最多 6 行/次）。
3. **hlh.31 自动更新修复**（B-71，P0）：用户点「退出并自动更新」后加载器消失、
   什么都不发生。两条独立根因：
   - `ProcessStartMode.detached` 在 Windows 上「成功返回 pid 但子进程根本不执行」，
     更新脚本从未启动；
   - `exit(0)` 硬终止时 CEF 线程仍在跑，CRT teardown fail-fast
     （事件日志 `0xc0000409` / `ucrtbase.dll`）。
   修法：普通模式启动 + 关 stdin/读掉输出 + 退出前 700 ms 存活校验 +
   关窗口正常退出（原生 `PostMessage(WM_CLOSE)`）+ 更新脚本自带 WinForms
   进度窗口（等待/解压/备份/覆盖/完成，等待时泵消息）。细节见
   `docs/07-backlog.md` 的 B-71。

## 待办（按优先级）

1. 请用户重进游戏页后点一次「用云端存档（覆盖本机并重启）」，确认是两次点击 +
   会重启（B-72）；存档面板里的回滚/删除/覆盖上传同理。
2. 请用户实机点一次「退出并自动更新」，确认整条链路：进度窗口 → 自动重启 →
   首页「已更新到 x」。
3. 请用户点一次游戏内「设置 → 全屏」（JS → Dart 这一段无法自动化）。
3. 多显示器 / DPI 缩放未覆盖（验证机只有一块 1024×768 虚拟显示器）。
4. `docs/07-backlog.md`：B-33（Android 本地资源首屏真机）、B-22（Windows CEF
   磁盘缓存补丁）未做。
5. 用户安装目录的旧版本备份 `D:\Program Files\gardendless-loader.backup`
   （440 MB）待用户确认后删除。
6. 两仓已提交到 hlh.35；下次改动前先看 `docs/02-branches.md` 的推送纪律。

## 硬约束（违反会直接造成损失）

- `upstream`（Dey410/GardendlessLoader）**只读**：不推、不改、不提 PR。
- 服务器地址 / 令牌 / 密码绝不写进受版本控制的文件，只用 `.env.local`（已忽略）。
- 下载/上传 >50 MB 走代理 **7901**（`~/.local/bin/bulk`）；AI 接口走 **7891**。
- 不要重启 `pvzge-save`、不要改 nginx（静态部署允许）；运维副作用动作交 Hermes。
- Windows 只能在 `ssh win`（`C:\Users\s2681\GardendlessLoader-src`，Flutter
  `C:\src\flutter`）上构建；**不要并发跑两个 Windows 构建**（会把 `dist/*.zip`
  写坏）；**不要整目录同步 `windows/`**（Linux 侧 `windows/flutter/ephemeral`
  是软链接，会打断 Windows 构建），只同步 `windows/runner`，必要时删掉
  `windows/flutter/ephemeral` 后 `flutter pub get`。
- 版本号：`bash tools/bump-version.sh` 递增 `-hlh.N`；APK 与 Windows 必须同一
  版本名且 versionCode 递增（Windows 发布脚本会拒收不递增的 code）。
- 测试基线只许上升；断言加进现有套件，不新建框架，**不要重建 `test/` 下的
  widget test**（本仓库有意移除）。
- 用户明确要求：**不要用 oracle / oracle-sol 子代理**做本项目的判断。
- 回执里的数字必须真跑出来；没跑就写 `not-run` 并说明原因。

## 怎么算做完

`bash tools/handoff.sh verify` 0 失败 → `flutter analyze` 干净 → 相关套件数字
不低于基线 → 产物 sha256 与回执一致 → `HANDOFF.md` 第 4 节验收清单勾完 →
按 `PROTOCOL.md` 第 3 节写回执（含真实命令输出片段）。

## 环境备注

- 实机测试（在 Windows 主机上跑，都用发布包）：
  `tools/test-windows-updater.ps1 -RealZip <zip>`（63 项）、
  `tools/test-windows-fullscreen.ps1 -Zip <zip>`（13 项）、
  `tools/test-windows-quit.ps1 -Zip <zip>`（5 项）。
- `tools/*.ps1` 必须 UTF-8 BOM + CRLF（`handoff.sh verify` 会检查）。
- ssh 会话里起的 GUI 进程 `MainWindowHandle` 恒为 0（已发布版也一样），
  要按 PID + 窗口类名 `EnumWindows` 找窗口；窗口样式/矩形仍然真实可测。
- 上一个会话 `ses_e8e5be916ffejhWrt8uFeafSBw` 在 OpenChamber 侧栏可能看不到：
  它在 `~/.local/share/opencode/opencode.db` 的 `session_v2.time_suspended`
  非空（被挂起），属于客户端显示问题，不影响本仓库状态。

----- 8< -----

## 维护说明

- 这份文件是**易变事实**的汇总，改完发版/修完缺陷后要顺手更新第「现在的状态」
  与「待办」两节；长期不变的东西不要复制到这里，指向 `AGENTS.md` / `docs/`。
- 与 `prompts/01-start.md` 的分工：01 是「最短开工指令」，本文件是「完整交接」。
