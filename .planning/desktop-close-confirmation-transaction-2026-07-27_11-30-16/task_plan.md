# 任务计划：desktop-close-confirmation-transaction

- 任务 ID：`desktop-close-confirmation-transaction-2026-07-27_11-30-16`
- 创建时间：`2026-07-27_11-30-16`

## 目标

连续触发多个终端关闭请求时，确认框始终绑定第一笔不可变事务；第二笔请求不得覆盖服务器、工作区或终端目标。

## 范围

- 把单个和批量终端关闭状态合并为一个 scoped 关闭事务。
- 所有关闭入口复用同一请求方法；确认与取消只操作该事务。
- 增加连续关闭、跨服务器、批量关闭和取消的回归测试。

## 非目标

- 不改变“哪些终端需要确认”的策略。
- 不改 daemon、协议、终端恢复或标签拖拽行为。

## 关键约束

- 破坏性动作必须绑定原始 server、workspace 和 session IDs。
- 确认框存在时拒绝新的关闭请求，不覆盖既有目标。
- Session 状态仍以对应 Runtime 的最新快照为准。

## 修改路径

- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/InspectorView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`

## 验证方式

- 运行新增针对性 Swift 测试。
- 运行 Desktop 全量测试与 release build。
- 运行 `pnpm check`、`pnpm build`、`git diff --check`。

## 验收标准

- [x] 连续请求关闭 A、B 后，确认只会结束 A。
- [x] 跨服务器的第二笔关闭请求不能改变第一笔事务的路由。
- [x] 取消第一笔事务后，A、B 都保持存活，随后可正常发起新请求。
- [x] 单个和批量关闭入口共用同一事务模型。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 单一 `PendingSessionTerminationRequest` | 两个可变 Published 状态会互相覆盖，单一事务才能原子绑定目标 |
| 事务只存 scoped IDs | 确认时重新从权威 Runtime 快照解析活 Session，避免使用过期对象 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
