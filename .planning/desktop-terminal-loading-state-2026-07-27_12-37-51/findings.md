# 调研与结论：desktop-terminal-loading-state

- 任务 ID：`desktop-terminal-loading-state-2026-07-27_12-37-51`
- 创建时间：`2026-07-27_12-37-51`

## 需求事实

- `TerminalPaneContent` 当前只有“alive → 终端”和“其他 → 终端已结束”两类。
- 布局会在 Runtime 首次快照前从 UserDefaults 恢复，因此 tab/session ID 已存在，但 `sessions` 仍为空。
- 新建分屏会先出现空 pane，再异步调用 `session.create`，期间 `emptyPane` 当前同样显示“终端已结束”。
- `session.create` 返回后，Controller 会注册 tab，但 `refresh()` 尚未把新 session 提交到 `connection.sessions`；当前内容分支仍会稳定误判结束。

## 真实调用链

- 启动：`restoreLayoutIfNeeded` → `TerminalPaneController.restoreTopology` → tab 已恢复 → `snapshotLoaded == false` → `TerminalPaneContent` 误判结束。
- 分屏：Bonsplit `didSplitPane` → `createTerminal` async RPC → empty pane → `emptyPane` 误显示结束。
- 权威完成：`RuntimeConnection.commitRefreshSnapshot` 设置 sessions 与 `snapshotLoaded` → `reconcileLayoutState` 清理真正失效 session。

## 调研结论

- 根因是视图把“未知/创建中”和“权威结束”合并，不是 Runtime 提前删除 session。
- 最小根修位于 `TerminalPanesView` 的内容状态映射，不需要协议或 daemon 改动。
- 正确状态为：创建 placeholder 或快照未加载 → loading；快照中 alive → active；快照已加载且非 pending 的 session 缺失/死亡 → ended。

## 技术决策

| 决策 | 证据 |
|---|---|
| 三态纯函数驱动 UI | 同一判定可覆盖首次加载、恢复布局、重连和真实结束，并可直接测试 |
| 不在客户端增加定时器 | `snapshotLoaded` 已是现有权威边界，额外延时只会掩盖竞态 |
| pending 创建状态放在 `Tab.isLoading` | RPC 返回与 refresh 提交之间仍需显式事实；Bonsplit 已有 spinner 和更新 API |
| cancelled creation 的删除 tombstone 放在 `RuntimeConnection` | 它跨 Controller restore 存活，并统一掌握 refresh、重连、RPC 去重与权威快照 |

## 风险与边界

- 已加载快照中的 dead session 仍显示结束，之后由 reconcile 收敛布局。
- 空 pane 创建失败后现有逻辑会移除 pane；加载提示不会掩盖错误弹窗。
- 用户可在 `session.create` 返回、refresh 提交前关闭 loading 标签。此时必须保留远端删除意图，否则删除失败或 Controller 重建后 session 会复活。
- 任意“缺少 session”的旧快照不能清除删除意图。只有 `session.remove` 已成功，且后续权威快照仍缺少 session，才算清理完成。

## 参考指针

- `apps/desktop-macos/Sources/TerminalPanesView.swift:8-22,94-155`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:617-654`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:164-197,291-354`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:1543-1555,1593-1690`
- `apps/desktop-macos/Sources/RuntimeConnection.swift:193,921-940`

## Subagent 复核

- attach transport exit 已由 Beta.23 修复，正常重连不会进入 ended 分支。
- 稳定复现集中在 split/new-tab 创建事务：零 tab pane，以及 create 返回到 refresh 提交之间。
- cmux 对 transient connecting/reconnecting 使用 spinner，只在权威退出后进入 ended。
