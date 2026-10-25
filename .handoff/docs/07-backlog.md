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

## P1

（本轮无未决 P1：B-05 / B-08 已关闭，见文末「已关闭」。）

## P2

- B-10 `pvzge-auth` 容器已停但 compose 定义仍在（宿主重启可能复活）。
- B-11 1Panel `IpWhiteList` 仍是内网段白名单（安全面收窄）。
- B-12 new-api 日志 3.1 GB 未清（磁盘）。
- B-13 GitLab 明文 DB/SMTP 密码待轮换。
- B-14 代理池 `.22` 的 Anthropic 规则固定路由到失效美国组（与客户端无关，运维遗留）。

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

`B-03 SAF 目录授权（决策：不做，保留候选目录 + 手填）→
候选列表已经覆盖「应用外部目录 + 各外置卷的应用目录」，都是 WebView 能直接读的真实路径；
SAF 返回的 content:// 树无法作为 WebView 的资源根，要支持它必须把校验/导入/迁移三条路径
全部重写成 Storage Access Framework 抽象，收益（U 盘/厂商二级目录）不足以承担回归风险。
本轮只补了选择框里的说明文案（`storageAndroidCandidatesHint`），让用户知道为什么没有系统选择器。`

`B-04 令牌对游戏 JS 可见 → 设备令牌不再进入页面。
游戏页只注入 3 小时有效的存档会话令牌（scope 限定读写存档、不带管理员组），
原生心跳/在线代理改读 0600 的宿主专用文件（长期设备令牌）；吊销设备令牌会连带失效所有会话。
断言：test-cloud-saves.sh 的 8.6 一节（会话令牌可读写、不能签发/吊销、过期 401、连带失效）+
check_game_host_contract.dart 的会话令牌解析与文件名校验。`

`B-05 历史存档保留 1000 → 300（按你的要求实现）→
每个（用户 / 游戏版本 / 存档键）独立裁剪，永远从最旧的删起，同一秒的 ts-n 按序号排序；
history 目录本身就在 by-version/<gv> 下，所以 1.6.1 的清理动不到 1.6.2。
断言：test-save-versions.sh 第 8.5 节 8 条（300 份上限、边界、最旧优先、同秒序号、跨版本/跨键隔离、非历史文件不动）。`

`B-08 Windows 自更新 → 检查 / 下载 / sha256 校验 / 退出并自动替换全部打通。
替换由外部 PowerShell 脚本执行：等进程退出 → 解压到临时目录并校验 exe 存在 → 整目录备份 →
robocopy 覆盖 → 失败自动回滚并重启 → 清理。安装目录不可写时直接拒绝，不启动脚本。
断言：check_update_manifest.dart 22 条（清单解析、版本判定、文件名防穿越）+ 脚本 BOM/CRLF；
脚本在 Windows 构建机的沙盒目录实测：文件替换、旧文件保留、备份清理、退出码 0。`

`B-15 公开仓历史里含服务器域名 → 已清理（2026-10-25）→
用 git filter-branch 对全部 branches+tags 做 tree-filter，把 tool/check_cloud_saves.dart 里的
域名字面量替换为 <server>；本地备份 bundle 在 /tmp/opencode/pre-purge-*.bundle（41 MB）。
重写后 origin/feature/app-update 与 private/main 均以 --force-with-lease 强推，
重新 fetch 后 git grep 全历史 0 命中；本地 refs/original 已删、reflog 过期、gc --prune=now。
注意：GitHub 仍可能按旧 commit SHA 缓存对象，若要求彻底不可达需向 GitHub Support 申请 purge；
域名本身不是凭据（仍需 authentik + Bearer），当前达标线是「源码与可达历史均无字面量」。`

`B-18 管理页看不到按版本分区的存档 → 已关闭（hlh.20）→
`/list` 改为返回 `saves[]`（legacy + 每个 by-version），普通用户只返回本人；
`/history`、`/version`、`/raw` 允许本人读取，跨用户仍需管理员；管理页按
`gameVersion` 展示并传递历史/回滚/下载/删除参数。游戏内「存档」按钮对所有
用户挂载，打开同一套面板。
断言：test-cloud-saves.sh 7.9 节 3 条（自助列表、跨用户 403、本人历史 200）+
8.5 节 4 条（我的存档、data-gv、按钮全员挂载、无独立上传按钮）。`
