# 07 待办与已知缺陷

> 优先级定义：P0 = 影响核心功能或安全；P1 = 明显体验缺陷或有数据风险；P2 = 打磨。
> **修完一条就把它移到本文件末尾「已关闭」并写断言名**，不要直接删除（便于回溯）。

## P0

### B-01 安卓在线形态缺真机验证
- 现象：`OnlineGameResourceClient` / `OnlineSessionHeartbeat` 只做到编译与路由冒烟，没有真机跑过。
- 风险：心跳若不生效，服务端永远认为没人在线，资源包重打包的「让路」机制失效（会在玩家手上换文件）。
- 要做：出验收清单（`docs/acceptance-android.md`）、加日志埋点、按用户回传日志定位。
- 判据：真机在线游玩 5 分钟后，服务端 `online/status` 的 `active > 0`；退出后 120 s 内归零。

### B-02 资源包管理 UI 双端不一致
- 现象：安装列表/切换/删除/改路径/迁移在两端的文案、按钮可用性、失败提示不完全一致。
- 风险：用户误操作删掉正在用的资源；或迁移时没被门禁拦住。
- 要做：对齐文案与状态反馈；确认四个门禁在所有入口都检查（见 `01-architecture.md` 第 6 节）。
- 判据：新增 UI 级断言（Dart 可测的部分）+ 手工清单覆盖每个入口。

### B-03 安卓 SAF 目录授权只做了候选目录
- 现象：`FilePicker.getDirectoryPath` 在安卓会返回 `content://`，已改为「应用外部目录 + 各外置卷」候选列表。
- 剩余风险：非标准路径（U 盘、部分厂商的二级目录）用户只能手填；手填错会被校验拦住但体验一般。
- 可选方案：接 SAF 持久化授权（`takePersistableUriPermission`）+ DocumentFile 读写封装。
- 注意：改动面大，先评估收益；若做，必须保证迁移/校验/导入三条路径都能用新抽象。

### B-04 令牌对游戏 JS 可见
- 现象：注入的桥脚本里带设备令牌，游戏页面的 JS 能读到。
- 风险：恶意资源包（用户导入第三方资源）可窃取令牌。
- 可选方案：native 代理层（WebView 侧不暴露令牌，改由原生带 Bearer 抓取）。成本高。
- 现状缓解：令牌可在存档页吊销；每用户最多 10 个。

## P1

### B-05 历史存档保留 1000 → 300 未决
- 需要产品决策（删旧版本不可逆），**等用户拍板**，agent 不要自行改。

### B-06 管理页 5 s 轮询没有 `visibilitychange`
- 现象：后台标签页仍在轮询，浪费请求。
- 做法：`document.addEventListener('visibilitychange', ...)` 暂停/恢复。

### B-07 设备标识历史数据缺失
- 现象：93 个历史存档版本「设备未知」（早期没记 `device` 字段）。
- 做法：展示层对缺失做兼容（显示「历史设备」），不回填。

### B-08 Windows 自更新缺失
- 现状：安卓有「检查更新→下载 APK→触发安装」；Windows 只能手动替换。
- 可选：下载 zip → 退出后由外部脚本替换（需要独立 updater 进程），复杂度中等。

### B-09 `.ps1` 编码陷阱没有自动化
- 现象：PowerShell 5.1 读无 BOM 的中文注释会崩。
- 做法：`tools/build-windows.ps1` 提交时保证 `utf-8-sig` + CRLF；可加一条 pre-commit 检查。

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

（示例格式）
`B-00 Windows 本地 ZIP 导入不可用 → 自写 StreamingZip（`tool/check_desktop_zip.dart` 11 项 + `stress_real_pack`）`
