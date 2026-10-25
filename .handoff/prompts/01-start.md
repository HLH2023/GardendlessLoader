读 `.handoff/HANDOFF.md`（主文档）→ `.handoff/PROTOCOL.md`（契约）→ `.handoff/docs/01`~`07`。

你的任务：`.handoff/state.json` 里的 `task`（当前 R-20261025-01，hlh.17）。

开工前必须做两件事：
1. `bash tools/handoff.sh verify` 必须 0 失败；`flutter analyze` 必须 No issues。
2. 把 `task.status` 改为 `accepted`，并在 `receipts[]` 写第一条回执，含**语义回读**：
   任务标题、当前版本号、测试基线数字（抄错即视为未通过）。

然后按 `HANDOFF.md` 第 3~4 节做，回执按 `PROTOCOL.md` 第 3 节格式写。
红线：不推 `upstream`；服务器地址/令牌绝不写进仓库文件；运维类副作用动作交给 Hermes。
