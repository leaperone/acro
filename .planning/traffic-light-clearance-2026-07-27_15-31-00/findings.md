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
- `WindowConfigurationView` 已监听 `didEnterFullScreen` / `didExitFullScreen`，但只重算 safe area，没有把状态交给所属 WorkbenchView。
- `TerminalPaneController.configuration` 把 bool 映射为 80pt。
- `TabBarView` 用 `rootNode.allPaneIds.first == pane.id` 决定哪个 pane 渲染 inset；`SplitViewContainer` zoom 时渲染 `zoomedNode`。

## 调研结论

- High 1：全屏空区不是 safe-area 问题，而是横向 traffic-light inset 的状态输入缺失。
- High 2：非首窗格 zoom 重叠不是 frame 偏移问题，而是 Bonsplit 选择 inset owner 时读取了不可见的原树 first pane。
- 正确 owner 是 `zoomedPaneId ?? rootNode.allPaneIds.first`。
- 正确 clearance 是 `leftSidebarPresentation == .hidden && !isMainWindowFullScreen`。
- 行为红测确认：zoom 第二窗格后唯一可见标签的窗口坐标 `minX` 为 `0`，没有拿到 80pt 避让。
- 行为红测确认：工作台窗口收到 `didEnterFullScreen` 后，渲染仍使用 controller 的 `80pt` leading inset。

## 技术决策

| 决策 | 证据 |
|---|---|
| 复用现有窗口通知 | 不新增 monitor，didEnter/didExit 已是权威事件 |
| WorkbenchView 保存窗口 fullscreen bool | `WindowGroup` 的多个窗口共享 model；全屏状态必须按窗口分域 |
| BonsplitView 接受渲染局部 override | 不改共享 controller configuration，其他窗口继续保留正常 80pt |
| Bonsplit 直接按可见 pane 决策 | 最短根修，不引入新的策略对象或配置项 |

## 风险与边界

- `WindowGroup` 可创建或恢复多个工作台窗口，而 Acro 的 model/controller 是共享的；把 fullscreen bool 放进 model 会让窗口互相覆盖。
- 全屏动画期间配置更新可能触发一次重新布局，必须验证顶部无残余空位且标签命中不回归。
- 真实全屏自动化在 CI 不稳定；配置链用行为测试，最终 Beta 做人工全屏验收。
- 测试不伪造 `.fullScreen` style mask；用两个 WindowConfigurationView 验证通知按 window 隔离，再验证渲染 override 不修改共享 controller。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitViewContainer.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
