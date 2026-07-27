# 任务计划：traffic-light-clearance

- 任务 ID：`traffic-light-clearance-2026-07-27_15-31-00`
- 创建时间：`2026-07-27_15-31-00`

## 目标

让顶部红绿灯占位只在“红绿灯真实存在且当前可见窗格需要避让”时出现，消除全屏 80pt 空槽，并防止放大非首窗格后标签压到窗口控制按钮下方。

## 范围

- Workbench 在每个窗口内维护全屏状态，只覆盖该窗口的标签栏渲染。
- 隐藏左侧栏时仅在非全屏保留 80pt 红绿灯占位。
- Bonsplit 放大任意窗格后，把 leading inset 交给当前唯一可见窗格。
- 添加真实配置与渲染行为回归测试。

## 非目标

- 不修改标签排序、跨窗格移动、分屏按钮或窗口拖动事务。
- 不在本增量增加 inactive first-mouse、右栏拖窗、双击系统偏好或显示器断开恢复。
- 不统一 28pt/38pt chrome 高度。

## 关键约束

- `isMovable=false` 与 Beta.28 标签命中修复必须保留。
- 全屏状态变化必须复用现有 didEnter/didExit 通知，不增加轮询。
- 非首窗格 zoom 退出后，原始首窗格重新获得 inset。
- 不重启 terminal daemon。

## 修改路径

- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Public/BonsplitView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitViewContainer.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 先运行旧实现会失败的全屏配置与非首窗格 zoom 渲染测试。
- `swift test --package-path apps/desktop-macos --filter TerminalPanesInteractionTests`
- `swift test --package-path apps/desktop-macos`
- `swift build --package-path apps/desktop-macos -c release`
- `pnpm check`、`pnpm build`、main CI package smoke。

## 验收标准

- 隐藏侧栏、非全屏：首个可见窗格保留 80pt inset。
- 隐藏侧栏、全屏：所有窗格 inset 为 0。
- 隐藏侧栏、放大第二或后续窗格：放大后的可见标签从 80pt 之后开始。
- 退出 zoom：原始首窗格恢复 inset，其他窗格不保留空位。
- 宽/紧凑侧栏行为不变；顶部点击、排序和分屏按钮继续通过。

## 未确认事项

无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 全屏状态留在 WorkbenchView | WindowGroup 可以创建多个窗口；窗口状态不能写入共享 model/controller |
| Bonsplit 支持只影响当前渲染树的 leading inset override | 手工 NSHostingController 边界不会自动传递普通 SwiftUI 状态，显式参数链最可靠 |
| leading inset 跟随 zoomedPaneId | zoom 后只有该 pane 被渲染，原 root first 已不代表可见首窗格 |
| 一次修两个 High | 两个症状都来自“固定占位没有跟随真实窗口/可见 pane 状态”的同一根因 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无 |
