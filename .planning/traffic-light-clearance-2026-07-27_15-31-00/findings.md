# 调研与结论：traffic-light-clearance

- 任务 ID：`traffic-light-clearance-2026-07-27_15-31-00`
- 创建时间：`2026-07-27_15-31-00`

## 需求事实

- Beta.28 顶边、点击和拖动测试只覆盖 key window、非全屏、宽侧栏、单窗格。
- 隐藏侧栏时 Acro 用 80pt `tabBarLeadingInset` 为红绿灯让位。
- 全屏时系统红绿灯消失，但配置仍保留 80pt。
- zoom 第二窗格时 Bonsplit 只渲染 zoomed pane，却仍只给原始 root first pane 加 inset。

## 真实调用链

- `WorkbenchModel.synchronizeTerminalPaneControllers` 只根据 `leftSidebarPresentation == .hidden` 计算 clearance。
- `WindowConfigurationView` 已监听 `didEnterFullScreen` / `didExitFullScreen`，但只重算 safe area，没有把状态交给 model。
- `TerminalPaneController.configuration` 把 bool 映射为 80pt。
- `TabBarView` 用 `rootNode.allPaneIds.first == pane.id` 决定哪个 pane 渲染 inset；`SplitViewContainer` zoom 时渲染 `zoomedNode`。

## 调研结论

- High 1：全屏空区不是 safe-area 问题，而是横向 traffic-light inset 的状态输入缺失。
- High 2：非首窗格 zoom 重叠不是 frame 偏移问题，而是 Bonsplit 选择 inset owner 时读取了不可见的原树 first pane。
- 正确 owner 是 `zoomedPaneId ?? rootNode.allPaneIds.first`。
- 正确 clearance 是 `leftSidebarPresentation == .hidden && !isMainWindowFullScreen`。
- 行为红测确认：zoom 第二窗格后唯一可见标签的窗口坐标 `minX` 为 `0`，没有拿到 80pt 避让。
- 行为红测确认：工作台窗口收到 `didEnterFullScreen` 后，缓存 controller 的 leading inset 仍为 `80`。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用现有窗口通知 | 不新增 monitor，didEnter/didExit 已是权威事件 |
| model 保存主窗口 fullscreen bool | 同步更新所有 workspace 的 TerminalPaneController configuration |
| Bonsplit 直接按可见 pane 决策 | 最短根修，不引入新的策略对象或配置项 |

## 风险与边界

- WindowGroup 当前只有主工作台使用这套 model；设置窗口不挂载 WorkbenchView，不会污染状态。
- 全屏动画期间配置更新可能触发一次重新布局，必须验证顶部无残余空位且标签命中不回归。
- 真实全屏自动化在 CI 不稳定；配置链用行为测试，最终 Beta 做人工全屏验收。
- 测试不伪造 `.fullScreen` style mask；用窗口权威 enter/exit 通知验证接线，用 model 配置断言验证最终 inset。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitViewContainer.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
