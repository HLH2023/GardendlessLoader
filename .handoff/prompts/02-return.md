# 交回模板（agent 交付时用）

1. 在 `state.json.task.status` 写 `review`，追加一条完整 `receipts[]`（字段见 PROTOCOL §3）。
2. 在 `docs/08-handoff-log.md` 追加同一份回执（人读版）。
3. 跑 `bash tools/handoff.sh verify`，必须 0 失败，把输出原样贴进回执的 `commands`。
4. 需要 Hermes 做的事（发布 Release、部署服务端、重打资源包）写进 `needsHermes`，不要自己动。

回执必填：`changed` / `commands`（真实命令与输出） / `tests`（各套件真实数字） /
`artifacts`（路径+字节+sha256） / `remaining`（新发现的 bug 同步进 07-backlog.md）。
