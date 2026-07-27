# 调研与结论：desktop-agent-attention-badges

- 任务 ID：`desktop-agent-attention-badges-2026-07-27_08-07-11`
- 创建时间：`2026-07-27_08-07-11`

## 需求事实

- 协议已有 `starting` / `working` / `waiting` / `done` / `error`，不需要扩展 schema。
- Acro 标签目前只同步 cwd 和 title，后台 Agent 状态变化没有顶部反馈。
- Bonsplit 已提供 `showsNotificationBadge` 以及未读点渲染。

## 真实调用链

- 新 Runtime `session.agentChanged` 直接增量应用 Agent；旧 daemon 缺少 payload 时触发快照刷新。
- `TerminalPanesView.tabMetadata` 生成 Equatable 快照，`onChange` 调用 `refreshTabMetadata()`。
- `TerminalPaneController.refreshTabMetadata()` 通过 `BonsplitController.updateTab` 同步标签属性。
- `didSelectTab` 是用户把后台标签标为已读的直接入口。
- 旧 `session.agentChanged` 只携带 session ID，连续事件可能在全量刷新合并时丢失中间 attention 状态。

## 调研结论

- 最小根方案是在 `TerminalPaneController` 保留每个 session 上次 Agent 状态与未读集合。
- 不能把 `done` 等状态永久映射为 badge，否则用户读取后会立即回弹。
- 分屏中每个 pane 已选中的 tab 都在可见区，应视为已读。
- 工作区隐藏时，其 pane 的 selected tab 仍是后台，不能按“已选中”直接清除。
- 新 daemon 事件应携带完整 Agent；桌面端独立保留 attention signal，不被随后 `working` 最终状态覆盖。
- refresh job 捕获启动时的 Agent 事件版本；事件之前启动的旧快照不能清除 signal，事件之后的权威快照可确认 `agent=nil`。
- 排队 refresh 只能在 predecessor 完成后、真正读取快照前捕获版本，否则会把事件之后读取的权威快照误判为旧快照。
- 每个 session 的最新事件版本用于保护 `sessions.agent`：旧快照不回滚增量状态，后续权威快照仍可清理。
- 快照权威性必须按 session 判定：A 的新事件不能阻止同一快照清理 B 已确认为 nil 的旧 signal。

## 技术决策

| 决策 | 证据 |
|---|---|
| 独立 attention signal | `waiting → working` 即使在同一视图刷新周期内发生，也不能丢掉中间提醒 |
| 在元数据快照加入 Agent state | 否则 SwiftUI `onChange` 不会在只改 Agent 状态时触发 |
| 元数据快照同时加入 `updatedAt` | Runtime hook 每次有效 Agent 事件都更新该值，可区分连续同状态事件 |
| 布局 restore 不清空未读 | 拖拽或服务端布局刷新不应把未读当成已读 |
| 旧 daemon 缺少 Agent payload 时返回 false | 复用现有 `scheduleRefresh()` 兼容路径，不强制立即重启持有 PTY 的 daemon |

## 风险与边界

- 重复 signal 必须幂等，否则会造成未读点回弹。
- session 或 agent 消失必须清理字典，避免长期累积和 ID 复用污染。
- 不改 `TabItemView`，避免输入热路径和 Equatable 边界回归。

## 参考指针

- `packages/protocol/src/models.ts:126`
- `apps/desktop-macos/Sources/TerminalPanesView.swift:47`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:80,207`
- `apps/desktop-macos/Sources/RuntimeConnection.swift:524,555,835`
- `apps/runtime/src/daemon/daemon.ts:724`
- `apps/desktop-macos/Vendor/Bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:295`
- `.tmp/cmux/Sources/Workspace.swift:4085`
