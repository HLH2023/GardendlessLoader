# 06 测试

## 1. 基线：1305 项（服务端 828 + 客户端 477）

```bash
# 服务端（745 项）—— 在 /home/hlh/pvzge 下跑。
# 除 cloud-saves 外都可指向临时实例，避免写真实存档：
#   BASE=http://127.0.0.1:<port> SAVE_LOCAL=$BASE DATA_ROOT=<tmp> ...
#   DATA_DIR=<tmp> PORT=<port> python3 save-api/server.py
bash  tools/test-cloud-saves.sh      # 117 云端存档全链路（含吊销、鉴权边界、连接复用、会话令牌、自助面板、静态部署漂移、冲突面板动作）
python3 tools/test-concurrency.py    # 28  并发写/锁/乐观版本号/逐玩家并发/首次 UID 绑定
bash  tools/test-save-versions.sh    # 159 版本隔离 + 逐键继承 + 多玩家合并/删除/历史 + UID 绑定 + 权限 + tombstone + JS 舍入版本号 + 多设备旧副本不登记 unchanged + 换号 expectedUid + 整包回滚身份/owner + 删除重置回滚标记 + 设备元数据只记真正写入 + 连续回滚事件 A/B + tombstone 超过 100 条不复活
dart run tool/check_desktop_channels.dart  # 68 桌面端平台通道 + 全屏(F11 消息路由) + 键盘焦点引导 + 更新启动链路
dart run tool/check_update_manifest.dart   # 54 清单 + Windows 更新脚本/回执契约（32→54）
dart run tool/check_windows_update_result.dart  # 38 更新回执解析（纯函数，含 BOM/坏 JSON）
node  tool/check_fullscreen_script.mjs   # 23 桌面全屏注入脚本（假 DOM 里跑状态机）
node  tool/check_keyboard_script.mjs     # 10 桌面键盘注入脚本（body 时序 + event.code 校正/去重）

# 只能在 Windows 主机上跑，不计入上面的基线（更新 54 / +RealZip 63、全屏 13、干净退出 5）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-updater.ps1 -IncludeSlow
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-fullscreen.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-quit.ps1 -Zip <发布包>
node  tools/test-sync-offline.js     # 473 sync.js 沙盒（单飞/force 快照与不可解析响应/启动基准/恢复接管/单玩家回滚回插/每代 pending 槽位/退避/401/换号 403/回滚/多玩家基准/删除 ACK/adopt generation 与竞争失败/换账号/迁移 pending/版本不匹配首传/换号归档写失败/generation 写满降级/回填同位竞争/跨版本 pending/接管写满不发布基准/运行期 adopt 新 epoch/换号目标队列失败/adopt 写失败/resync 云端重建/手动上传入口与结果事件）
node  tools/test-sync-live.js        # 9   sync.js ⇄ 真实 server.py 契约（新玩家 ID 回填/双设备/删除/tombstone）
node  tools/test-admin-baseline.js   # 21  手动上传后只推进已发送且被接受的玩家
node  tools/test-ui-dialogs.js       # 21  存档前端不用原生对话框 + 破坏性动作二次确认状态机（含迟到 ACK 身份复核）（同源/跨源/跨版本/无 profileVer/目标版本未知/老服务端 saved 判定）
#      App 版用刚生成的产物：APP_SYNC=<tmp>/app-sync.js node tools/test-sync-offline.js

# 客户端（316 项）—— 在仓库根目录跑
dart run tool/check_local_server.dart          # 42  本地服务器（注入/Range/穿越/软链/并发/固定端口）
dart run tool/check_storage_migration.dart     # 63  迁移 + 日志自愈 + 空间预检 + 事务门禁
dart run tool/check_desktop_zip.dart <zip>     # 11  流式解压 + zip-slip
dart run tool/check_game_host_contract.dart    # 94  原生退出原因 + 会话令牌 + 凭据 + 启动 + 存档分区 + 桌面固定端口 + 日志换段清理 + iOS/OHOS guard 注入 fail closed
node  tool/check_local_save_guard.mjs          # 65  本机版本保护状态机（账号+版本隔离/generation 槽归档/升级降级恢复/pendingGv/归档失败阻断目标版本）
dart run tool/check_cloud_saves.dart           # 9   离线：keySources 逐键来源 + 旧服务端页面回退
dart run tool/check_update_manifest.dart       # 32  Windows 更新清单 + 版本判定 + 更新脚本编码/引号/回滚 + CEF 日志上限
```

> 2026-10-26 第十轮：`test-sync-offline` 381→411（Web 顶层锁 + iframe、
> blocked 迟到回调、运行期采用云端回滚），`check_game_host_contract` 73→83
> （迟到 401 上下文、guard 原子写/fail closed、`localSaveGuardRequired`）。
> 2026-10-26 hlh.25：补 B-65 后 `check_game_host_contract` 83→94（iOS/OHOS
> guard 注入、required fail-closed、失败后不加载）。
> 2026-10-26 13:42：Web/App 面板统一「上传本机」入口，`test-sync-offline`
> 411→441（App 生成物 443）；静态 9/9，cloud-saves 117/0/0。
> 2026-10-26 15:23：Web 单标签页撤掉 iframe、改 pass 交接（修登录后黑屏），
> `test-sync-offline` 441→473（App 生成物 475）；390 行的 [80]/[83]/[86]
> 换成 pass 语义，[95] 加源码契约（不再含 `__pvz_game_frame` 等）。
> 2026-10-27 hlh.26：新增 `check_desktop_channels` **21**（Windows 初始化崩溃的
> 平台通道契约），客户端 316→337。
> 2026-10-27 hlh.27（Windows 实机验证那轮）：`check_update_manifest` 32→**53**（更新回执、
> 每条失败分支、失败重启、脚本兜底 catch、ZipFile 解压、robocopy /R /W、备份清理、
> 下载目录默认位置）；新增 `check_windows_update_result` **38**（回执 JSON 解析与 logCode 契约）；
> `check_desktop_channels` 21→**23**（`ExternalUrlService` 弃用 `cmd /c start`）。
> 客户端 337→**398**。总数 **1205**（服务端 807 + 客户端 398）；Android JVM 另有 46 项。
> 另有 `tools/test-windows-updater.ps1` **52 项**只能在 Windows 实机跑（覆盖覆盖/回滚/
> 各种失败），不计入上面的基线。
> 2026-10-27 hlh.28：`check_desktop_channels` 23→**38**（Windows 全屏：原生窗口通道、
> WS_POPUP、还原、F11 顺序、注入脚本、页面接线），新增 `check_fullscreen_script` **23**
> （Node 假 DOM 跑注入脚本状态机），客户端 398→**436**。总数 **1243**；另有
> `tools/test-windows-fullscreen.ps1` **13**（真窗口 style/rect）同为 Windows-only。
> 2026-10-27 hlh.29：`check_desktop_channels` 38→**53**、`check_update_manifest`
> 53→**54**（自动更新启动链路：普通模式、存活校验、quit/WM_CLOSE、进度窗口、
> robocopy 退出码），客户端 436→**452**，总数 **1259**。Windows 实机新增
> `tools/windows_update_spawn_check.dart`（由 `test-windows-updater.ps1` 第 9 例驱动，
> 54 项基数、带 `-RealZip` 时 63 项）与 `tools/test-windows-quit.ps1`（干净退出）。
> （`./gradlew :app:testDebugUnitTest`）。`APP_SYNC` 现在切换整套用例的源，
> 不再只让 [5] 跑 App 变体。

# Android 原生视口单测（JVM，不需要设备）
cd android && ./gradlew :app:testDebugUnitTest --tests '*GameViewportSizeTest*'
# 4 项：21:9 / 20:9 / 4:3 按窗口原样返回；固定 17:9 与非法尺寸
# 手动上传/在线桥等 JVM 可测逻辑直接跑全量：
cd android && ./gradlew :app:testDebugUnitTest
# 其中 OnlineGameResourceClientTest 3 项：单引号桥（Dart 实际产物）、双引号兼容、
# 缺 token 拒绝猜测。Android 的 android.jar 里 org.json 是抛异常的 stub，
# 所以 app/build.gradle 加了 testImplementation "org.json:json:20240303"。

`<zip>` fixture 不是任意包：`check_desktop_zip.dart` 对内容有明确预期
（3 个正常条目 + 1 个越界条目 + 一个 3 MiB 的 `assets/big.bin`）。
按下面这段生成，否则会报「解压返回文件数 2」或在 `big.length()` 处抛
`PathNotFoundException`：

```python
import zipfile
with zipfile.ZipFile('pack.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('index.html', '<html></html>')
    z.writestr('sub/dir/nested.txt', 'nested')
    z.writestr('assets/big.bin', b'B' * (3 * 1024 * 1024))   # 必须 3 MiB
    z.writestr('../../evil.txt', 'PWNED')                     # 越界条目：必须被跳过
```

> 2026-10-25 修正：旧版文档写「任意带嵌套目录的 ZIP」，与实际断言不符；
> 按旧文档生成的包会让套件以非零退出码失败，被误当成产品回归。

## 2. 压力用例（真实资源包）

```bash
dart run tool/stress_real_pack.dart /var/www/pvzge-res/pvzge-res-<ver>.zip /tmp/realpack
```

判据：文件数与磁盘一致、峰值 RSS 远小于包体（当前基线 **294 MB / 1313 MB**）。
如果改成 `package:archive` 会变 1600 MB —— 这是回归红线。

## 3. 新增测试的规矩

1. **不新建框架**：服务端断言加进现有 4 个脚本；客户端优先加进现有 `tool/check_*.dart`，
   需要直接执行生成 JS 的状态机行为时用已有 `tool/check_*.mjs`（如 `check_local_save_guard.mjs`）。
2. 每条断言必须有一个明确的名字（推进「什么场景下应该怎样」），失败要能看出差在哪。
3. 断言里不要写死环境相关数字（端口、绝对路径），用变量或临时目录。
4. 涉及安全的用例（越权、伪造头、zip-slip）必须同时有**正例**（合法请求成功）和**反例**。
5. 已知假阳性：`test-cloud-saves.sh` 的吊销用例曾因「公网伪造 `X-Authentik-Username`」而假失败——
   nginx 现在会剥掉该头，吊销必须走内部 API（服务端 loopback 端口）。
6. **跨语言契约要真的比对两边源码**：原生宿主写 `game_exit_result.json`、Dart 只按字符串认
   原因，漂移时 `consumeExitResult()` 会静默返回 null。`check_game_host_contract.dart` 直接
   解析 Kotlin 枚举与 Dart 枚举做双向比对，新增原因忘了同步会立刻红。

## 4. 测试卡住了怎么查

| 现象 | 常见原因 |
|---|---|
| `501` / `000` | 先看是不是测试脚本自己的 URL 拼装错了（`--resolve`、`$HOST` 未展开）；**但也可能是后端 keep-alive 连接污染**：未授权 POST 提前返回、请求体没读完，残留字节被当成下一个请求行 → `501 Unsupported method ('{"id":...}GET')`。已在 2026-10-25 修复并有独立断言 |
| `401` 但令牌看起来有效 | 令牌文件被删/过期，或走了需要 authentik 的 location |
| 并发用例偶发失败 | 上一次运行残留锁文件；清 `saves/*/…lock` 或换测试用户 |
| 迁移用例失败 | 目标盘空间不足（预检会拒绝），或上一次的 `.pvz-migrating.json` 没清 |
| `check_desktop_zip` 报文件数 2 | fixture 不对，见第 1 节 |

## 5. 手工验收（用户执行，agent 出清单）

安卓端真机验收清单见 `docs/acceptance-android.md`；
上游的手工清单在 `docs/acceptance-checklist.md`（**不要改动上游文件**）。

7. **2026-10-25 修复的假阳性**：`printf '%s' "$VAR" | grep -q ...` 在 `set -o pipefail`
   下会因 `grep -q` 提前退出、`printf` 收到 SIGPIPE 而随机失败（实测 200 次里 186 次）。
   断言统一改成 `grep -q ... <<<"$VAR"` 或先落变量再 grep；新增断言不要再写管道形式。
8. **静态文件漂移**：Web 面板的 `ui.js/admin.html/conflict.html` 由 nginx 直接 alias
   `/var/www/pvzge-save`。改完源码必须跑 `cd /home/hlh/pvzge && bash tools/deploy-static.sh`；
   `bash tools/deploy-static.sh --check` 与 `test-cloud-saves.sh` 的静态一致性断言会拦住旧副本。
