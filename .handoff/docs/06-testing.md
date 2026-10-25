# 06 测试

## 1. 基线：251 项

```bash
# 服务端（142 项）—— 在 /home/hlh/pvzge 下跑
bash  tools/test-cloud-saves.sh      # 55  云端存档全链路（含吊销、鉴权边界）
python3 tools/test-concurrency.py    # 19  并发写/锁/乐观版本号
bash  tools/test-save-versions.sh    # 27  版本隔离 + 向下兼容迁移 + 回滚
node  tools/test-sync-offline.js     # 41  客户端 sync.js 沙盒（冲突/退避/401/回滚）

# 客户端（109 项）—— 在仓库根目录跑
dart run tool/check_local_server.dart       # 43  本地服务器（注入/Range/穿越/软链/并发）
dart run tool/check_storage_migration.dart  # 55  迁移 + 日志自愈 + 空间预检
dart run tool/check_desktop_zip.dart <zip>  # 11  流式解压 + zip-slip
```

`<zip>` fixture 可以用任意带嵌套目录的 ZIP；验证 zip-slip 需要一个含 `../../evil.txt` 条目的包。
生成方法（Python）：

```python
import zipfile
with zipfile.ZipFile('pack.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('index.html','<html></html>')
    z.writestr('sub/dir/nested.txt','nested')
    z.writestr('../../evil.txt','PWNED')
```

## 2. 压力用例（真实资源包）

```bash
dart run tool/stress_real_pack.dart /var/www/pvzge-res/pvzge-res-<ver>.zip /tmp/realpack
```

判据：文件数与磁盘一致、峰值 RSS 远小于包体（当前基线 **294 MB / 1313 MB**）。
如果改成 `package:archive` 会变 1600 MB —— 这是回归红线。

## 3. 新增测试的规矩

1. **不新建框架**：服务端断言加进现有 4 个脚本，客户端加进现有 3 个 `tool/check_*.dart`。
2. 每条断言必须有一个明确的名字（推进「什么场景下应该怎样」），失败要能看出差在哪。
3. 断言里不要写死环境相关数字（端口、绝对路径），用变量或临时目录。
4. 涉及安全的用例（越权、伪造头、zip-slip）必须同时有**正例**（合法请求成功）和**反例**。
5. 已知假阳性：`test-cloud-saves.sh` 的吊销用例曾因「公网伪造 `X-Authentik-Username`」而假失败——
   nginx 现在会剥掉该头，吊销必须走内部 API（服务端 loopback 端口）。

## 4. 测试卡住了怎么查

| 现象 | 常见原因 |
|---|---|
| `501` / `000` | 测试脚本自己的 URL 拼装错了（`--resolve`、`$HOST` 未展开），不是产品 bug |
| `401` 但令牌看起来有效 | 令牌文件被删/过期，或走了需要 authentik 的 location |
| 并发用例偶发失败 | 上一次运行残留锁文件；清 `saves/*/…lock` 或换测试用户 |
| 迁移用例失败 | 目标盘空间不足（预检会拒绝），或上一次的 `.pvz-migrating.json` 没清 |

## 5. 手工验收（用户执行，agent 出清单）

安卓端真机验收清单见 `docs/acceptance-android.md`（待建，本任务 P0 之一）；
上游的手工清单在 `docs/acceptance-checklist.md`（**不要改动上游文件**）。
