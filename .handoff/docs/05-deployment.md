# 05 服务端部署

> 所有带副作用的部署动作由 **Hermes** 执行；agent 只改源码与测试，不重建容器、不重载 nginx。

## 1. 拓扑

```
公网 ──▶ frps(aliyun) ──▶ nginx 网关（core 主机） ──┬─▶ pvzge 容器      <loopback>:8088  游戏本体
                                                          ├─▶ pvzge-save     <loopback>:8090  存档 API（python:3.13-alpine）
                                                          ├─▶ 静态目录 /var/www/pvzge-save/  注入脚本 + 页面
                                                          └─▶ 静态目录 /var/www/pvzge-res/   资源 zip / APK
```

- 服务器地址由 `PVZGE_SERVER` 环境变量/secret 提供，**任何文件里都不出现字面量**。
- 存档 API 源码在 `/home/hlh/pvzge`（私有仓 `HLH2023/pvzge-server`）。

## 2. 目录与挂载

```
/home/hlh/pvzge/
  save-api/{server.py,sync.js,ui.js,app-sync.js,app-ui.js,admin.html,app-admin.html,version-check.js}
  saves/                          # 存档数据（gitignore）
    <user>/by-version/<gameVersion>/<key>.json
    <user>/by-version/<gameVersion>/.history/ts-<n>.json
    .app_tokens/<sha256>.json     # 设备令牌（0600）
    .local_status_token           # 本机脚本共享令牌（0600）
  tools/{deploy-save-api.sh,publish-apk.sh,build-resource-zip.py,make-app-sync.py,test-*.sh}
容器挂载： ./save-api:/app:ro    ← 目录挂载，不是单文件（单文件 bind mount 会踩 inode 陷阱）
静态目录： /var/www/pvzge-save/  /var/www/pvzge-res/
```

## 3. 关键路由（nginx）

| 路由 | 鉴权 | 说明 |
|---|---|---|
| `/_save/app/{load,save,whoami,tokens,history,restore,list,version}` | Bearer（`auth_request`） | 存档 API；`/list`、`/history`、`/restore` 需 `authentik Admins` |
| `/_save/app-sync.js`、`/_save/app-ui.js` | Bearer | document-start 注入的桥脚本 |
| `/_save/app/res/*` | Bearer | 资源清单 / zip / APK / Windows 更新（Range/ETag） |
| `/_save/app/res/win/*` | Bearer | Windows 客户端更新：`manifest.json` + `<version>-<code>-windows-x64.zip` |
| `/_save/online/*` | Bearer | 反代游戏本体；**不做 sub_filter**（避免双份 sync.js） |
| `/_save/api/*` | authentik `auth_request` | 签发页面用 |
| `/_res/apk/*` | authentik | 浏览器直接下载 APK |
| `/_save/online/status` | 共享令牌 `X-Pvz-Local` 或回环 | 是否有在线玩家（供资源包重打包让路） |

**红线**：凡「后端自己认 Bearer 身份」的 location，必须显式清空
`X-Authentik-Username/Groups/Email/Name/Uid`（nginx 里置空字符串即可），否则公网可伪造管理员。

## 4. 部署存档 API

```bash
cd /home/hlh/pvzge
bash tools/deploy-save-api.sh      # 生成共享令牌 → 重建容器 → 健康检查 → 冒烟
```

脚本会自动：确保 `saves/.local_status_token` 存在（0600，40 字符随机）、重建 `pvzge-save`、
`/load` `/save` 冒烟。改完 `server.py` 一定要跑它，并核对容器内文件 md5 与源一致：

```bash
docker exec pvzge-save md5sum /app/server.py; md5sum save-api/server.py
```

## 5. 更新注入脚本 / 静态页面（sync.js / ui.js / admin.html / conflict.html）

浏览器版由 nginx 直接 alias `/var/www/pvzge-save`，App 版还要再生成
`app-sync.js / app-ui.js / app-admin.html`。两者必须一起更新，否则会出现
「源码改了、线上还是旧副本」——2026-10-25 的 Web 面板不可用就是这样来的。

```bash
cd /home/hlh/pvzge
bash tools/deploy-static.sh          # 生成 App 版 + 复制浏览器版 + 逐文件 cmp
bash tools/deploy-static.sh --check  # 只核对，不写；CI/收尾必跑
```

脚本会先 `node --check` 所有 JS，再用 `make-app-sync.py` 生成到临时目录，
最后复制 9 个文件并逐个 `cmp`；`/var/www` 不可写时自动用 docker 挂载写入。
`test-cloud-saves.sh` 也会对 6 个浏览器版文件做源/线上一致性断言。
App 版的 `app-sync.js` 是 SHIM + `sync.js`，哈希必然不同，不能用 md5 直接比。

> 2026-10-25 修正：旧文档写 `md5sum save-api/sync.js /tmp/pvz-static/app-sync.js`
> 「必须一致」是错的——`app-sync.js` 由 SHIM（Bearer 改写层）+ `sync.js` 拼成，
> 体积与哈希必然不同。照旧文档核对会误判成部署失败。

## 6. 资源包

```bash
python3 tools/build-resource-zip.py            # 打包前会查 /online/status，有在线玩家则推迟
# 产物：/var/www/pvzge-res/pvzge-res-<gameVersion>.zip（约 1.3 GB，ZIP_STORED）
```

`--ignore-online` 可强制打包（**慎用**：在线玩家正在读游戏文件）。

## 7. 发布 APK

```bash
bash tools/publish-apk.sh <apk> --version 0.9.0-hlh.N --notes "…"
# 落到 /var/www/pvzge-res/apk/ + 更新 manifest.json（App 内检查更新读它）

bash tools/publish-windows.sh <zip> --version 0.9.0-hlh.N --notes "…"
# 落到 /var/www/pvzge-res/win/ + 更新 win/manifest.json（桌面端检查更新读它）
```

## 8. 备份

存档目录定期打包：`/home/hlh/pvzge-backups/saves-<stamp>.tar.gz`。
**动 `saves/` 结构前先备份。**
