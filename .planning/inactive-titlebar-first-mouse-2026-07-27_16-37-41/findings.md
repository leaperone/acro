# 调研与结论：inactive-titlebar-first-mouse

- 任务 ID：`inactive-titlebar-first-mouse-2026-07-27_16-37-41`
- 创建时间：`2026-07-27_16-37-41`

## 需求事实

- 用户要求继续审查并改善 Acro UI/UX，当前 High 问题是非激活窗口顶部控件第一次点击只激活窗口，原动作丢失。
- 顶部标签栏空区已在 Beta.29 修复，本任务不能再改变该布局。
- cmux 的正确设计原则是只让注册过的标题栏交互区域接受 first mouse，而不是让整个窗口接受。

## 真实调用链

- 标签主体和关闭按钮由 Bonsplit `NonDraggableHostingView` 内的 SwiftUI gesture/Button 接收。
- Acro 内建 new terminal / splitRight / splitDown 走普通 SwiftUI Button，不走已有 `SplitActionMouseDownNSView`。
- `BonsplitTabBarHitRegionRegistry` 已由标签栏背景登记整条可见标签栏区域。
- 标签栏空白拖窗由 `TabBarDragZoneView.DragNSView` 接收；侧栏标题拖窗由 `WorkbenchView.WindowDragNSView` 接收。
- 终端正文由 `AcroTerminalNSView.acceptsFirstMouse = true` 单独控制。

## 调研结论

- `NonDraggableHostingView` 当前没有覆写 `acceptsFirstMouse`，所以标签、关闭和普通分屏按钮在非 key 窗口第一次点击时不会执行。
- 两个原生拖窗视图也没有接受 first mouse，第一次拖动手势可能只激活窗口。
- 最小根修是复用已有标签栏 registry，在共享 hosting view 只接受标签栏内事件，并给两个最深层拖窗视图明确接受 first mouse。

## 技术决策

| 决策 | 证据 |
|---|---|
| 共享 hosting view 按 registry 判断 | 现有 registry 已覆盖整条标签栏并按 window 和可见层级过滤 |
| 不逐个包装 SwiftUI 控件 | 逐个包装会遗漏标签空白区，也会复制命中逻辑 |
| 不修改根 Workbench hosting view | 全局 true 会让侧栏、普通按钮和其他内容在后台窗口直接执行 |

## 风险与边界

- AppKit 可能由最深层 `DragNSView` 决定 first mouse，必须用真实 hit view 测试确认。
- first mouse 只决定事件是否送达，不能绕过关闭确认或改变标签拖拽、双击语义。
- 真实 UI 验证不能替代双窗口事件回归测试，二者都需要。

## 参考指针

- Acro：`apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/SplitNodeView.swift`
- Acro：`apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/TabBarView.swift`
- Acro：`apps/desktop-macos/Sources/AcroDesktop/WorkbenchView.swift`
- Acro：`apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- cmux：`.tmp/cmux/Sources/App/CmuxMainWindow.swift`
- cmux：`.tmp/cmux/Sources/WindowDragHandleView.swift`
