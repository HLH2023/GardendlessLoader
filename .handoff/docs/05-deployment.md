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
| `/_save/app/res/*` | Bearer | 资源清单 / zip / APK（Range/ETag） |
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

## 5. 更新注入脚本（sync.js / ui.js）

这两个文件会被「打包进 App 注入」的版本（`app-sync.js` / `app-ui.js`）使用，
改完必须重新生成并落到静态目录：

```bash
APP_SYNC_OUT_DIR=/tmp/pvz-static python3 tools/make-app-sync.py
# 目录 root 所有 → 用 nsenter 以宿主 root 落地
docker run --rm --privileged --pid=host --net=host --entrypoint nsenter python:3.13-alpine \
  -t 1 -m -u -i -n -p -- sh -c "cp -f /tmp/pvz-static/* /var/www/pvzge-save/ && chown root:root /var/www/pvzge-save/*"
# app-sync.js = SHIM + sync.js（生成器会插入 Bearer 改写层），两者 md5 本来就不同；
# 正确的核对方式：生成器不报错 + 体积 = shim + sync，且浏览器版与源文件一致
md5sum save-api/sync.js /var/www/pvzge-save/sync.js      # 必须一致（浏览器版）
grep -c 'pvzBridgeUrl' /var/www/pvzge-save/app-admin.html  # 必须 ≥1（App 版管理页）
```

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
```

## 8. 备份

存档目录定期打包：`/home/hlh/pvzge-backups/saves-<stamp>.tar.gz`。
**动 `saves/` 结构前先备份。**
