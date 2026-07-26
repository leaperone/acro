# 执行进度：close-tab-before-refresh

- 任务 ID：`close-tab-before-refresh-2026-07-27_04-40-34`
- 创建时间：`2026-07-27_04-40-34`
- 当前状态：`complete`

## 已完成

- 核对全部关闭入口、共享 mutation 路径、Bonsplit controller 和焦点所有权调用链。
- 确认当前实现先逐出 surface、后等待 refresh、最后关闭标签。
- 增加可控 RPC/refresh 的真实 `terminateSession` 行为测试。
- 修复前测试按预期失败 6 项，直接覆盖 refresh 等待窗口中的标签、选择、layout 和焦点状态。
- 将成功顺序改为本地关闭/fallback 激活 → surface evict → refresh。
- 增加当前 workspace 后台标签不抢焦点和 RPC 失败不改变 UI 的覆盖。
- reviewer 最终复核通过，无 blocker。

## 进行中

- 无。

## 修改文件

- `.planning/close-tab-before-refresh-2026-07-27_04-40-34/*`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码调用链 | RPC 后先 evict，再 refresh，最后 close | 已确认缺陷 |
| 修复前定向测试 | 1 test，6 个期望失败 | 按预期失败 |
| PR #128 第一提交 CI | desktop-macos 因新行为测试失败 | 红色证据已确认 |
| `TerminalPanesInteractionTests` | 16 项 | 通过 |
| Desktop 全量测试 | 80 XCTest + 23 Swift Testing | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | 通过，仅既有 `import.meta` 警告 | 通过 |
| reviewer 复核 | 活动/后台/最后标签、RPC 失败、显式 reconcile | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 0 | 无 |
