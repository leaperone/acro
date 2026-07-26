# 任务计划：terminal-tab-title-refresh

- 任务 ID：`terminal-tab-title-refresh-2026-07-27_03-59-16`
- 创建时间：`2026-07-27_03-59-16`

## 目标

让 runtime 的 `session.title` 增量事件立即更新当前 Bonsplit 顶部标签标题，不等待下一次完整快照或工作区切换。

## 范围

- 覆盖 `RuntimeConnection.sessions` 到可见 `TerminalPaneController` 标签元数据的更新链。
- 增加真实 SwiftUI 宿主回归测试。

## 非目标

- 不为标题事件执行整套工作区布局对账。
- 不改变标题优先级、OSC 协议或 daemon 采集逻辑。

## 关键约束

- 避免在终端输入热路径增加日志和 I/O。
- 只刷新当前可见 Bonsplit controller 的标签元数据。

## 修改路径

- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 先提交会失败的行为测试，再提交修复。
- 针对性 Swift Testing、Desktop 全量测试、`pnpm check`、`pnpm build`。

## 验收标准

- `session.title` 从空变为 `vim` 后，已渲染标签立即显示 `vim`。
- 标题变化不触发完整 `snapshotRevision`/布局 reconcile。
- 相同标题事件不产生额外 UI 更新。

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
| 在 `TerminalPanesView` 观察 sessions | 它持有当前可见 controller，可直接刷新标签元数据，不必扩大 snapshotRevision 语义 |
| 不递增 `snapshotRevision` | OSC 标题变化不应触发整套工作区布局对账 |
| 指纹只覆盖 controller 当前渲染的 tabs | 避免后台 session 元数据变化触发可见 controller 的无关刷新 |
| 外层快照独立携带 `ScopedResourceID` | 即使两个 controller 的 tab 元数据都为空，workspace/server 切换也必须刷新当前 controller |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
