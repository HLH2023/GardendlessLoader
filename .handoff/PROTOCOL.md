# 接力协议（Hermes ⇄ OpenChamber agent）

本文件是唯一契约。双方都只按这里的字段与状态机行事；不靠聊天记录传状态，不靠记忆。

## 0. 为什么是文件而不是对话

接力要跨会话、跨工具、跨时间。对话会丢、会压缩、会被误读；文件在磁盘上，可校验、可回溯、
可 diff。所以：**状态在 `.handoff/state.json`，知识在 `.handoff/HANDOFF.md` + `.handoff/docs/`，
交互只有「大文档 + 配套文件 + 短提示词」三件套。**

## 1. 目录与职责

```
.handoff/
  PROTOCOL.md           ← 本文件（契约，双方都不得单方面改）
  HANDOFF.md            ← 交接大文档（架构/状态/当前需求/必读顺序）
  state.json            ← 唯一状态源（版本、分支、任务、回执）
  docs/01..08-*.md      ← 配套文件（架构/分支/版本/构建/部署/测试/待办/接力日志）
  prompts/01-start.md   ← 交给 OpenChamber 的短提示词（≤10 行）
  prompts/02-return.md  ← agent 交回时的回执模板
  skills/gardendless-dev/SKILL.md  ← agent 侧技能（同时装入 opencode 全局 skills）
tools/handoff.sh        ← 校验器（status / verify / new-task / seal）
```

- **Hermes 负责**：切任务、写大文档、维护 `state.json`、校验回执、发版与带运维的操作（服务端、
  容器、nginx、frpc、Windows 构建机）。
- **OpenChamber agent 负责**：仓库内编码 —— Dart/Kotlin/JS/Python 改动、本地 `flutter analyze`、
  本机可跑的测试套件、git commit/push 到 `origin` 与 `private`。**不做**带副作用的运维操作。

## 2. 状态机（枚举值写死，不得自创）

`draft → dispatched → accepted → in_progress → (review | blocked) → done`

| 状态 | 谁写 | 含义 |
|---|---|---|
| `draft` | Hermes | 任务在写，不可开工 |
| `dispatched` | Hermes | 文档齐备、短提示词已给，等 agent 认领 |
| `accepted` | agent | agent 已读完全部必读文件并回执「我读到了什么」，可以开工 |
| `in_progress` | agent | 正在改代码 |
| `blocked` | agent | 卡住，必须在回执里写清卡点、已尝试的方案、需要谁做什么 |
| `review` | agent | 改完自测通过，等 Hermes 校验 |
| `done` | Hermes | 校验通过（含测试数字与产物哈希复现），任务关闭 |

规则：
1. 状态只能按上表前进或退到 `blocked`；`review → in_progress` 允许（校验不合格打回）。
2. 每次状态变化必须同时追加一条 `receipts[]`（agent）或 `handoffLog[]`（Hermes）。
3. `accepted` 必须是**语义回读**：回执里要写出「我理解的任务目标 / 我读到的版本号 / 我读到的测试基线」，
   不能只写「已收到」。抄错版本号即判定未通过。
4. 不允许跳过 `accepted` 直接 `in_progress`。

## 3. 回执（RECEIPT）必填字段

写到 `.handoff/state.json` 的 `receipts[]` 与 `.handoff/docs/08-handoff-log.md`：

```markdown
## R-20261025-01 / <agent 名字> / <ISO 时间>
- status: review
- readBack: { taskTitle, versionBefore, testsBaseline: "251 项（142 服务端 + 109 客户端）" }
- changed: [文件级清单，逐条一句话说明为什么改]
- commands: [实际执行的命令 + 关键输出片段，不得编造]
- tests: { analyze: "No issues", suites: [{name, passed, failed}], total }
- artifacts: [{path, bytes, sha256}]
- remaining: [已知未解 / 新发现的 bug，进 07-backlog.md]
- needsHermes: [必须由 Hermes 做的运维/发布动作]
```

**回执里的数字必须是真跑出来的。** 没跑就写 `not-run` 并说明原因，不允许写「应该通过」。
校验器会比对 `tests.total` 与各 suite 之和是否自洽。

## 4. 交接三件套的边界

| 件 | 长度 | 内容 |
|---|---|---|
| 大文档 `HANDOFF.md` | 一屏到三屏 | 架构速览、当前状态、**这次要做什么**、验收标准、必读文件顺序 |
| 配套文件 `docs/0x-*` | 每篇一主题 | 细节：分支/版本/构建/部署/测试/待办 |
| 短提示词 `prompts/01-start.md` | ≤10 行 | 只写「读哪几个文件 + 状态怎么改 + 交付什么」 |

大文档里**不重复** docs 的细节，只给指针；docs 里**不写**当前任务的验收标准。这样每次新任务
只改 `HANDOFF.md` + `state.json` + `prompts/01-start.md`，docs 保持稳定。

## 5. 校验（Hermes 侧）

```bash
bash tools/handoff.sh status      # 打印当前任务/状态/版本/测试基线
bash tools/handoff.sh verify      # 校验：文件齐备 + state.json 合法 + 回执字段完整 + 敏感信息扫描
bash tools/handoff.sh new-task --id R-YYYYMMDD-NN --title "..."   # 切新任务（重置回执、置 draft）
bash tools/handoff.sh seal        # 记录当前工作树与文档的哈希（防止交接内容被悄悄改动）
```

`verify` 通过 = 允许把状态推进到 `done`。

## 6. 红线

1. **个人服务器地址、令牌、密码一律不进受版本控制的文件**。需要时用环境变量
   `PVZGE_SERVER` / 仓库 secret / `~/.hermes/credentials/*`（0600），文档只写变量名。
   `tools/handoff.sh verify` 会扫描 `greatbox`、`pvz_`、`Bearer ` 之后的字面量等模式。
2. 不得改动 `upstream` 远端，不得向上游提 PR。
3. 不得重启 core 宿主机；`frpc`(.157)、路由 `iStoreOS`(.41) 不碰。
4. 安卓真机测试由**用户**执行；agent 负责出可执行的验收清单、解读日志、按日志修代码。
5. 服务端带副作用的部署（容器重建、nginx 重载、资源包重打包）由 Hermes 执行，agent 只改源码与测试。
