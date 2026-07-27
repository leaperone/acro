# 调研与结论：desktop-close-confirmation-transaction

- 任务 ID：`desktop-close-confirmation-transaction-2026-07-27_11-30-16`
- 创建时间：`2026-07-27_11-30-16`

## 需求事实

- 当前关闭确认框同时观察 `pendingSessionTermination` 和 `pendingSessionTerminations`。
- 多个关闭入口可以在确认框仍显示时继续写入这两个状态。

## 真实调用链

- 关闭 A → `requestSessionTermination` 写入单个 Session 和 `pendingServerId`。
- 关闭 B → 同一方法覆盖 Session 与服务器目标。
- 用户点击确认 → `WorkbenchView` 此时才读取最新 Published 值，因此可能结束 B 而不是 A。
- 批量请求还会先清空单个状态再写数组，形成同类覆盖。

## 调研结论

- 根因不是弹框本身，而是关闭请求没有不可变事务边界。
- 最小根修是单一 scoped 请求；请求存在时拒绝第二笔写入。
- Workspace 和 Inspector 的直接赋值入口也必须改走共享请求方法。

## 技术决策

| 决策 | 证据 |
|---|---|
| 事务包含 `ScopedResourceID` 和去重后的 session IDs | 同时固定服务器、工作区和目标集合 |
| 确认时重新解析 alive Sessions | 避免确认期间 Session 已结束或服务器被移除时误操作 |

## 风险与边界

- 事务存在时忽略新的关闭请求；这是 cmux 同类确认状态的行为，避免堆积多个破坏性弹框。
- 本轮不改变所有 alive Session 都需要确认的既有策略。
- 原生 `confirmationDialog` 的真实点击生命周期没有 UI 自动化覆盖；同步取走事务再创建 Task 的调用顺序已由源码和单元测试验证。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchModel.swift:138-165,851-904,1273-1302`
- `apps/desktop-macos/Sources/WorkbenchView.swift:189-201,312-324`
- `apps/desktop-macos/Sources/SidebarView.swift:1332`
- `apps/desktop-macos/Sources/InspectorView.swift:42`
