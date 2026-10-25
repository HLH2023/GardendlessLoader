# 08 接力日志

> 只追加，不改写历史。Hermes 记录 dispatch/关闭，agent 记录接受/进行/阻塞/交付。
> 机器可读版本在 `state.json`，这里是人读的时间线。

## 2026-10-25 / Hermes / dispatch R-20261025-01

- **背景**：hlh.16 发布完成。本轮把 Windows「下载资源」形态真正打通（自写流式 ZIP），
  并修掉一批状态机与令牌生命周期的缺陷。251 项测试全绿。
- **关键发现（留给后继者避免重复踩）**：
  1. `package:archive` 的 `decodeStream` 会把整包内容留在内存（1.31 GB 包 → 峰值 1600 MB），
     桌面解压必须走 `lib/src/services/streaming_zip.dart`（同包峰值 294 MB、6.9 s）。
  2. 桌面 `prepareDesktopGame()` 早期没有启动互斥，连点会起两个服务器 + 两个窗口。
  3. 在线形态曾在 `GameSession` 构造**之后**才拉服务器清单，导致心跳上报旧游戏版本。
  4. 原生心跳 `stop()` 曾在主线程同步发网络请求（`onDestroy` 最长阻塞 10 s，ANR 风险）。
  5. 令牌被 401 拒绝后不会清登录态，云功能一直静默失败。
  6. 存储迁移没有日志，断电会留下「搬一半」的半残状态；也没有空间预检。
  7. 服务端 `safe_user()` 会把用户名里的 `.`/`-` 剥掉，与 `/save` 建目录用的原始名不一致，
     导致管理员查/删不到这类用户的存档。
  8. Windows 构建机删 `build/` 必须连 `.dart_tool/` 一起删，否则 `MSB3037/3073`。
- **交付**：`.handoff/` 接力包（协议、状态、7 篇文档、短提示词、agent 技能、校验器）。

## 2026-10-25 / Hermes / 交接包自检

- `bash tools/handoff.sh verify` 结果见下一条（首次建立后由 Hermes 跑一遍并记录）。

<!-- 以下是 agent 的回执区，按 PROTOCOL.md 第 3 节格式追加 -->
