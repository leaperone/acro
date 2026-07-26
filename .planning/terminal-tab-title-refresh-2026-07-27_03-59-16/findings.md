# 调研与结论：terminal-tab-title-refresh

- 任务 ID：`terminal-tab-title-refresh-2026-07-27_03-59-16`
- 创建时间：`2026-07-27_03-59-16`

## 需求事实

- OSC 标题会通过 `session.title` 增量事件写入 `RuntimeConnection.sessions`。
- 用户可见的 Bonsplit 标签标题由 `TerminalPaneController.refreshTabMetadata()` 更新。

## 真实调用链

- `RuntimeConnection.applyIncrementalEvent` 更新 sessions，但不递增 `snapshotRevision`。
- `WorkbenchView` 只在 `snapshotRevision` 变化时 schedule reconcile。
- `TerminalPaneController.update` 只有布局变化或 synchronize 调用时才刷新标签元数据。

## 调研结论

- 当前 `session.title` 数据已更新，但已渲染的 Bonsplit tab 没有收到 `updateTab`，因此标题停留在旧值。
- 直接递增 `snapshotRevision` 能碰巧刷新，但会让高频标题变化运行完整布局对账，不是根因方案。
- 行为测试在修复前稳定失败：connection title 已为 `vim`、revision 不变、controller identity 不变，但渲染 tab 仍为 `tmp`。
- 最终由 `TerminalPanesView` 观察当前 Bonsplit controller 实际渲染 tabs 的 `sessionId/cwd/title` 指纹，并调用当前 controller 的 `refreshTabMetadata()`；相同元数据不会触发 onChange。
- 外层观察值独立包含 `ScopedResourceID`，因此两个 controller 都没有 tab 元数据时，workspace/server 切换仍会刷新新 controller。
- sessions 先构建字典，再投影渲染 tabs，复杂度为 `O(runtime sessions + rendered tabs)`。
- 刷新前校验 controller 的 server 对应当前 runtime identity，避免 server 切换瞬间把旧 runtime 元数据写入新 controller。
- reviewer 复核通过：`initial: true` 覆盖首次显示、后台 workspace 切入与空 metadata 切换；刷新后指纹不变，不会形成循环。

## 技术决策

| 决策 | 证据 |
|---|---|
| 可见 TerminalPanesView 直接刷新 controller metadata | 标题属于标签投影，不属于工作区拓扑或服务端快照一致性 |
| 只观察 Bonsplit 当前渲染 tabs | 后台或未渲染 session 的标题变化不应影响当前 controller |
| 保留资源作用域外层 key | metadata 为空时仍需区分 workspace/server controller |

## 风险与边界

- 指纹不包含 cols/rows/agent/alive，终端尺寸、Agent 状态和存活状态仍由既有快照对账处理，不造成标签元数据的无意义刷新。

## 参考指针

- `RuntimeConnection.swift:551-586`
- `WorkbenchView.swift:122-125`
- `TerminalPaneController.swift:55-78`
- `TerminalPanesView.swift:6-22`
