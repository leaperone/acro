# 执行进度：desktop-agent-attention-badges

- 任务 ID：`desktop-agent-attention-badges-2026-07-27_08-07-11`
- 创建时间：`2026-07-27_08-07-11`
- 当前状态：`ready_for_delivery`

## 已完成

- 已复核协议、Runtime 事件、SwiftUI 快照、PaneController 与 Bonsplit badge 调用链。
- 已确认本增量不需要改协议或 Vendor 代码。
- 已增加后台 Agent attention 事件、未读集合与选中清除逻辑。
- 已将 `state + updatedAt` 纳入 SwiftUI 标签元数据快照。
- 已修复隐藏工作区的已选标签被误判为已读。
- 已将 Agent 事件改为新 daemon 增量传递，并保留旧 daemon 全量刷新兼容。
- 已将 attention signal 与最终 Agent 状态分离，快速 `waiting → working` 仍保留提醒。
- 已为 refresh job 加入 Agent 事件版本，在途旧快照不得清除 signal，后续权威快照可清理 `agent=nil`。
- 已将排队 refresh 的版本捕获移到真正开始读取前，并以每 session 事件版本防止 `sessions.agent` 被旧快照回滚。
- 已将 signal 清理从全局版本改为按 session 判定，一个 Agent 的新事件不会污染其他 session。
- 独立 diff 复核已通过，没有剩余 critical / high / medium 问题。
- 已完成针对性和全量本地验证。

## 进行中

- 无。代码、测试和交付前复核已经收敛；PR、合并和发布状态在用户交付核对中单独记录。

## 修改文件

- `.planning/desktop-agent-attention-badges-2026-07-27_08-07-11/*`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Tests/RuntimeConnectionEventTests.swift`
- `apps/runtime/src/daemon/daemon.ts`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 项目基线 | worktree 指引、planning 和 ignore 约束有效 | 通过 |
| 首次针对性 Swift 测试 | worktree 缺少忽略的 Ghostty header，未进入测试执行 | 环境阻断 |
| 行为红测 | 2 项测试在旧实现上出现 3 个预期失败 | 通过 |
| `TerminalPanesInteractionTests` | 25 项通过 | 通过 |
| Desktop 全量 Swift | 81 XCTest + 34 Swift Testing 通过 | 通过 |
| Bonsplit | 204 项通过 | 通过 |
| `pnpm check` | TypeScript 检查与 15 项 Node 测试通过 | 通过 |
| `pnpm build` | CLI/runtime 构建通过；仅现有 `import.meta` 警告 | 通过 |
| release scripts | 7 项 Python unittest 通过 | 通过 |
| 文案 / 本地化 | 本增量没有新增用户文案 | 不适用 |
| 独立 diff 复核 | 逐 session 事件版本、隐藏工作区和快速状态跃迁均通过 | 通过 |
| base merge probe | 与 `origin/main` 无冲突 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `GhosttyKit/ghostty.h` 不存在 | 1 | 将复用主 checkout 现有同版本产物后重跑 |
| 隐藏工作区红测 | 1 | 旧判定按预期失败；加入当前 workspace 条件后通过 |
| 排队 refresh 版本复核 | 1 | 新增双 session、两段 refresh 队列测试；A 的旧 nil 不回滚，B 的权威 nil 同快照清理，后续权威 nil 再清 A |
