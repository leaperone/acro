# 任务计划：close-tab-before-refresh

- 任务 ID：`close-tab-before-refresh-2026-07-27_04-40-34`
- 创建时间：`2026-07-27_04-40-34`

## 目标

关闭活跃终端成功后，立即从 Bonsplit 移除标签、同步选中 fallback 标签并恢复焦点，再逐出旧 surface 和执行权威 refresh，消除网络等待期间的空白与失焦。

## 范围

- 调整 `terminateSession` 成功后的本地 UI 状态顺序。
- 让共享 `closeTab` 路径为新选中的 fallback 会话申请焦点所有权。
- 增加真实 controller + 可暂停 refresh 的行为回归测试。

## 非目标

- 不改变 RPC 的 remove/kill fallback 语义。
- 不为失败 RPC 做乐观关闭；只有服务端确认成功后才改变 UI。
- 不改变 workspace 删除和非标签关闭流程。

## 关键约束

- UI 必须在服务端 mutation 成功后立即响应，不等待网络 refresh。
- refresh 仍是服务端权威对账，不负责驱动首次可见关闭。
- 所有关闭入口继续走共享 `terminateSession` / `closeTab` 路径。

## 修改路径

- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 两提交回归：先提交会失败的行为测试，再提交修复。
- 定向 Swift Testing、Desktop 全量测试、`pnpm check`、`pnpm build`。

## 验收标准

- refresh 被暂停时，被关闭标签已经消失，fallback 标签已选中。
- controller identity 不变，避免 reconcile 重建。
- fallback 会话收到 terminal focus request 和 focus claim。
- RPC 失败时标签与 surface 保持不变并展示错误。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 服务端 mutation 成功后先关闭本地 tab | 既不做失败前的乐观删除，又消除 refresh 网络等待造成的空白 |
| fallback focus 放在共享 `closeTab` | 覆盖按钮、快捷键、菜单、surface 自行退出和会话已死等所有入口 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
