# 07 待办与已知缺陷

> 优先级定义：P0 = 影响核心功能或安全；P1 = 明显体验缺陷或有数据风险；P2 = 打磨。
> **修完一条就把它移到本文件末尾「已关闭」并写断言名**，不要直接删除（便于回溯）。

## P0

### B-01 安卓在线形态真机验证（埋点与清单已完成，等真机）
- 现状：`OnlineSessionHeartbeat` 现在每次 enter/leave 都写结构化日志
  （`game.heartbeat / heartbeat_sent|heartbeat_failed`，含 `statusCode`、`durationMs`、
  `phase`）；401/403 会停止心跳、写 `online_token_rejected` 并带
  `tokenRejected` 原因退回启动器；`GameActivity` 补了 paused/resumed/stopped 生命周期日志。
- 已完成：`docs/acceptance-android.md` 验收清单。
- 剩余：真机跑一遍（用户执行）。判据不变：在线游玩 5 分钟后服务端 `online/status`
  的 `active > 0`；退出后 120 s 内归零。
- 断言：`tool/check_game_host_contract.dart` 的 `GameActivity 心跳回调里上报令牌失效` /
  `在线令牌失效时使用 TOKEN_REJECTED`。

### B-02 资源包管理 UI 双端一致性（门禁已补，等真机复核）
- 事实核对（2026-10-25）：本版本**没有**「多包安装列表 / 手动切换 / 删除某个包」的 UI，
  导入即「安装 + 校验 + 原子切换」，旧槽自动清理。因此不存在「误删正在用的包」的入口；
  原条目描述的删除按钮并不存在，是文档与实现的偏差，不是缺失功能。
- 已修：迁移与切形态原先只查四个内存门禁，不查持久化事务状态。崩溃恢复窗口
  （`manifest.transactionState` 停在 extracting/validating/readyToActivate）里仍可迁移，
  会把半成品槽整体搬走。现在 `resourceTransactionBusy()` 统一判定，
  迁移/切形态/导入三处都查。
- 剩余：真机按 `docs/acceptance-android.md` 第 4 节走一遍「迁移中/导入中」互斥。
- 断言：`tool/check_storage_migration.dart` 的「事务状态 <state> 的忙判定」7 条
  （覆盖全部 `TransactionState` 枚举值）。

### B-03 安卓 SAF 目录授权只做了候选目录（待决策，未动）
- 现状：`FilePicker.getDirectoryPath` 在安卓返回 `content://`，已改为候选目录 + 手填。
- 为什么没做：接 SAF 持久化授权要同时改造「迁移 / 校验 / 导入」三条路径，改动面大；
  当前候选列表已覆盖主流的应用外部目录与外置卷，收益不足以在本轮承担回归风险。
- 需要：用户拍板是否值得为 U 盘/厂商二级目录做 SAF 抽象。

### B-04 令牌对游戏 JS 可见（待决策，未动）
- 现状：注入的存档桥里带设备令牌，游戏页面 JS 可读 → 恶意第三方资源包可窃取。
- 为什么没做：彻底修需要在原生/桌面本地服务器做「请求级 Bearer 注入」，同时把令牌
  从桥脚本里拿掉。安卓在线形态已有代理层可复用，但本地形态（Android 直读文件、
  Windows `LocalResourceServer`）要各做一套，且要处理 CORS 与 Origin 白名单。
- 现状缓解：令牌可在存档页吊销、每用户最多 10 个；验收清单已提示不要导入来路不明的包。
- 需要：用户拍板是否接受「成本高、收益是防第三方资源包」的取舍。

## P1

### B-05 历史存档保留 1000 → 300 未决
- 需要产品决策（删旧版本不可逆），**等用户拍板**，agent 不要自行改。

### B-08 Windows 自更新缺失
- 现状：安卓有「检查更新→下载 APK→触发安装」；Windows 只能手动替换。
- 可选：下载 zip → 退出后由外部脚本替换（需要独立 updater 进程），复杂度中等。
- 本轮未做：需要独立的 updater 可执行文件与签名校验，超出「UI 收口」范围。

## P2

- B-10 `pvzge-auth` 容器已停但 compose 定义仍在（宿主重启可能复活）。
- B-11 1Panel `IpWhiteList` 仍是内网段白名单（安全面收窄）。
- B-12 new-api 日志 3.1 GB 未清（磁盘）。
- B-13 GitLab 明文 DB/SMTP 密码待轮换。
- B-14 代理池 `.22` 的 Anthropic 规则固定路由到失效美国组（与客户端无关，运维遗留）。

### B-15 公开仓历史里含服务器域名（已修源码，历史待清理）
- 现象：`origin`(HLH2023/GardendlessLoader) 是**公开**仓，历史提交 `0f23799` 的
  `tool/check_cloud_saves.dart` 里有一行 `defaultValue: '<服务器域名>'`。
- 已做：源码已改为 `String.fromEnvironment('PVZGE_SERVER')` 无默认值，并加运行时缺失提示；
  `tools/handoff.sh verify` 新增「源码敏感扫描」一节把它固化成断言。
- 未做（**需要用户拍板**）：重写公开仓历史。命令参考（在本地备份分支后执行）：
  ```bash
  git branch backup/pre-purge-$(date +%s)
  git filter-repo --path tool/check_cloud_saves.dart --invert-paths --force   # 或只替换该字面量
  git push --force-with-lease origin HEAD:refs/heads/feature/app-update
  ```
  注意：GitHub 仍可能通过提交 SHA 缓存旧对象，彻底清除需向 GitHub 支持申请 purge。
  域名本身不是凭据（访问仍需 authentik + Bearer），因此以「不再扩散 + 源码干净」为当前达标线。

## 明确不归你（agent）做的

- 重启 core 宿主机、重建/重载 nginx、重打资源包、发布 Release → **Hermes**
- 安卓真机安装与点击 → **用户**
- 向上游提 PR → **没人做，禁止**

## 已关闭

`B-00 Windows 本地 ZIP 导入不可用 → 自写 StreamingZip（`tool/check_desktop_zip.dart` 11 项 + `stress_real_pack`）`

`B-06 管理页 5 s 轮询没有 visibilitychange → 后台标签页停止轮询、切回立即补一次刷新
（`tools/test-cloud-saves.sh` 的 `管理页后台标签页暂停轮询`）`

`B-07 设备标识历史数据缺失 → 缺 device 字段显示「历史设备（未记录）」，不回填
（`tools/test-cloud-saves.sh` 的 `早期无 device 字段的存档显示为历史设备`）`

`B-09 .ps1 编码陷阱没有自动化 → tools/handoff.sh verify 增加「build-windows.ps1
为 UTF-8 BOM + CRLF」断言（`Windows 构建脚本编码` 一节）`

`B-16 存档 API 连接污染导致偶发 501（2026-10-25 新发现）→ do_POST 先鉴权后读体，
未授权请求的 body 残留在 keep-alive 连接里，被 http.server 当成下一个请求行
（`501 Unsupported method ('{"id":...}GET')`）；修复为先读完 body 再鉴权，超限时读完丢弃并
关闭连接。断言：`tools/test-cloud-saves.sh` 的 `未授权 POST 不污染 keep-alive 连接`；
注意该断言在服务端容器重新部署前会保持失败（源码已修，部署归 Hermes）。`

`B-17 check_desktop_zip 的 fixture 说明与实现不符（2026-10-25 新发现）→ 按文档「任意
带嵌套目录的 ZIP」生成的包会让套件在 `big.length()` 处抛 PathNotFoundException；
已把精确 fixture（3 条目 + 3 MiB assets/big.bin + 越界条目）写进 docs/06-testing.md。`
