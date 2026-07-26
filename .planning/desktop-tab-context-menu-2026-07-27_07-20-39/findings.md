# 调研与结论：desktop-tab-context-menu

- 任务 ID：`desktop-tab-context-menu-2026-07-27_07-20-39`
- 创建时间：`2026-07-27_07-20-39`

## 需求事实

- Acro 当前显式 `allowsTabContextMenu: false`，因为 Bonsplit 默认菜单包含大量 Acro 未实现的动作。
- 用户需要的是 cmux 同款有效交互，不是把开关直接翻开。

## 真实调用链

- `TabContextMenuBuilder` 固定构建 rename、close、move、browser、pin、unread、zoom 等全部菜单。
- `BonsplitController.requestTabContextAction` 仅对 full-width 内建处理，其余交给 delegate。
- `TerminalPaneController` 已持有 tab/session 映射、相邻 pane 查询和布局持久化。
- `WorkbenchModel` 的单标签终止已实现 `session.remove` 失败时回退 `session.kill`，但没有批量确认入口。

## 调研结论

- 根因是 Bonsplit 缺少宿主动作可见性契约；直接打开菜单会产生大量无效项。
- 关闭左右/其他需要批量 Runtime 终止，不能调用多次单标签确认。
- 相邻 pane 移动、特定 pane 新建和 zoom 已有 Bonsplit 原生 API，可直接复用。
- 红测确认当前不存在宿主菜单白名单和批量会话终止状态；相邻窗格动作也尚未路由。

## 技术决策

| 决策 | 证据 |
|---|---|
| 白名单在最终 NSMenu 上递归裁剪 | 不重写完整菜单；默认 nil 保持 cmux/Bonsplit 现有行为。 |
| 不开放 full-width | Acro 尚未持久化该状态，菜单开放后重建会丢失。 |

## 风险与边界

- vendored Bonsplit 新增的是通用、默认关闭的宿主能力，需确保默认菜单快照完全不变。
- UI 自动化目标仍不可用，真实右键视觉需热替换后人工验收。

## 参考指针

- `Vendor/bonsplit/.../BonsplitConfiguration.swift:45-136`
- `Vendor/bonsplit/.../TabItemView.swift:1346-1584`
- `TerminalPaneController.swift:174-282`
- `WorkbenchModel.swift:794-1037`
