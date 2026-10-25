# 06 测试

## 1. 基线：417 项（服务端 226 + 客户端 191）

```bash
# 服务端（226 项）—— 在 /home/hlh/pvzge 下跑
bash  tools/test-cloud-saves.sh      # 102 云端存档全链路（含吊销、鉴权边界、连接复用、会话令牌、自助面板、静态部署漂移、冲突面板动作）
python3 tools/test-concurrency.py    # 19  并发写/锁/乐观版本号
bash  tools/test-save-versions.sh    # 54  版本隔离 + 迁移 + 回滚 + 历史保留 + force/空档正反例
node  tools/test-sync-offline.js     # 51  客户端 sync.js 沙盒（冲突阶段/保留本机/退避/401/回滚/Web 版本兜底）

# 客户端（191 项）—— 在仓库根目录跑
dart run tool/check_local_server.dart          # 43  本地服务器（注入/Range/穿越/软链/并发）
dart run tool/check_storage_migration.dart     # 63  迁移 + 日志自愈 + 空间预检 + 事务门禁
dart run tool/check_desktop_zip.dart <zip>     # 11  流式解压 + zip-slip
dart run tool/check_game_host_contract.dart    # 47  原生退出原因契约 + 会话令牌 + 凭据 + 启动 + 存档分区 + 桌面宿主
dart run tool/check_update_manifest.dart       # 27  Windows 更新清单 + 版本判定 + 更新脚本编码/引号/回滚
```

# Android 原生视口单测（JVM，不需要设备）
cd android && ./gradlew :app:testDebugUnitTest --tests '*GameViewportSizeTest*'
# 4 项：21:9 / 20:9 / 4:3 按窗口原样返回；固定 17:9 与非法尺寸

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

1. **不新建框架**：服务端断言加进现有 4 个脚本，客户端加进现有 5 个 `tool/check_*.dart`。
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
