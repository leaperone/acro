# 调研与结论：close-tab-before-refresh

- 任务 ID：`close-tab-before-refresh-2026-07-27_04-40-34`
- 创建时间：`2026-07-27_04-40-34`

## 需求事实

- 用户持续要求 review/debug Acro UIUX；关闭当前标签时存在空白和焦点竞态。
- Apple 风格直接反馈要求服务端确认后立即反映关闭结果，不能把 UI 响应绑在后续网络刷新上。

## 真实调用链

- 标签关闭入口包括标签按钮、菜单、快捷键和 session/surface 退出。
- 活会话入口统一走 `requestKillTab` → `terminateSession`。
- 当前成功顺序是 RPC → evict surface → await refresh → `closeTab`。
- `closeTab` 会同步 Bonsplit/controller、selectedSessionId 和 focus request，但没有为 fallback 调用 `maybeClaimFocus`。

## 调研结论

- 旧顺序在 refresh 等待期间保留被选中的 tab，却先拆掉其 NSView/surface，形成可见空白和失焦。
- refresh reconcile 与末尾显式 close 还可能同时修改 controller，造成无意义竞态。
- 正确顺序是 RPC → closeTab/fallback focus → evict killed surface → refresh reconcile。
- 修复前行为测试在 refresh provider 挂起时稳定失败：controller 仍有 2 个 tab、focused/selected 仍是被关闭会话、layout 未删除、focus request 未增加，也没有 fallback `session.claimFocus`。

## 技术决策

| 决策 | 证据 |
|---|---|
| 用可暂停 refresh 的集成测试 | 能直接观察网络等待期间的 controller、选择和焦点状态，旧实现稳定失败 |
| 给 RuntimeConnection 增加 RPC provider 测试 seam | 现有 refresh provider 已支持可控快照，缺少可控 mutation RPC 是测试真实生产路径的唯一缺口 |

## 风险与边界

- 最后一个标签关闭后没有 fallback，不应发 focus claim。
- 后台 workspace 关闭不应抢当前 workspace 焦点。
- RPC 失败前不改变 UI，避免误删仍存活的会话。

## 参考指针

- `WorkbenchModel.swift:743-764, 992-1014`
- `TerminalPaneController.swift:162-172`
- `AcroTerminalView.swift:145-153, 573-595`
- `TerminalPanesInteractionTests.swift`
