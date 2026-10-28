读 `AGENTS.md`（范式与判定方法）→ `.handoff/PROTOCOL.md`（契约）→ `.handoff/HANDOFF.md`（主文档）→ 其指示的 `.handoff/docs/*`。
如果只想「一句话进入状态」，直接读 `.handoff/prompts/04-resume.md`（当前版本的完整交接：事实快照、刚做完什么、待办、硬约束）。

你的任务：`.handoff/state.json` 里的 `task`（当前 R-20261025-04；hlh.29 已发布，状态 `review`）。

开工前必须做三件事：

1. `bash tools/handoff.sh status` 与 `bash tools/handoff.sh verify`（必须 0 失败）。
2. `flutter analyze` 必须 `No issues`。
3. 若 `task.status` 是 `dispatched`，改成 `accepted` 并写第一条回执，含**语义回读**：
   任务标题、当前版本号、测试基线数字（抄错即视为未通过）。

然后按 `HANDOFF.md` 第 3~4 节做，回执按 `PROTOCOL.md` 第 3 节格式写。
红线：不推 `upstream`；服务器地址/令牌绝不写进仓库文件；运维类副作用动作交给 Hermes；
用户明确要求不要用 oracle / oracle-sol 子代理做本项目判断。
