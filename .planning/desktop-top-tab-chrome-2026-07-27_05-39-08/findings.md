# 调研与结论：desktop-top-tab-chrome

- 任务 ID：`desktop-top-tab-chrome-2026-07-27_05-39-08`
- 创建时间：`2026-07-27_05-39-08`

## 需求事实

- 用户明确认为 Acro 顶部标签栏相较 cmux 残缺，并反馈标签间拖拽不可发现、顶部有空区。
- 当前 main 已开启 `allowTabReordering`，并有真实鼠标事件测试证明中心点拖拽能重排。

## 真实调用链

- `AcroApp.WindowGroup(.hiddenTitleBar)` → `WorkbenchView` → `TerminalPanesView` → `BonsplitView` → `TabBarView`。
- `TabBarView` 用 `@AppStorage("workspacePresentationMode")` 决定 standard/minimal，但 Acro 没有设置该值，因此默认 standard。
- 同窗格拖拽由 `TabBarManualReorderTrackingView` 捕获 down/drag/up，4pt 阈值后计算插入位置，松手调用 `pane.moveTab`，delegate 再持久化布局。

## 调研结论

- Acro vendored Bonsplit 与最新 cmux vendor 的标签视图、样式和拖拽实现逐字一致，不能靠再次复制代码修复。
- Acro 宿主固定隐藏标题栏，Bonsplit 却运行 standard：右侧按钮常驻、空白 chrome 不承担 minimal 的窗口拖动/双击语义，形成用户可感知的不一致。
- 当前顶部补偿测试只验证负 padding 数学；新增真实 window frame 断言后，当前 main 的标签顶边已与内容顶边对齐，说明 `2d9a5c3` 已修复几何空区。

## 技术决策

| 决策 | 证据 |
|---|---|
| 启动时显式设为 minimal | 让既有 Bonsplit 自己提供 cmux 的完整顶部 chrome 行为，改动最少且不分叉 vendor |
| 用真实窗口 frame 和顶部指针事件验收 | 直接覆盖用户反馈，避免纯函数和 controller 测试产生假阳性 |

## 风险与边界

- `workspacePresentationMode` 是 Bonsplit 当前的进程级 AppStorage 键；Acro 只有一种主窗口 presentation，因此固定 minimal 不会丢失用户可选能力。
- 真实 Computer Use 不可用，最终视觉反馈边界需要用户在热替换 dev app 上确认。
- 合成 NSEvent 从扩展 hit slop 的最顶部起拖会触发 AppKit 模态拖动并挂住测试；这不能作为物理指针失败证据，测试分离为真实顶边几何和稳定的标签中心拖拽。

## 参考指针

- `apps/desktop-macos/Sources/AcroApp.swift:163-177`
- `apps/desktop-macos/Sources/WorkbenchView.swift:15-92,354-425`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:273-301`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:802-1175,1985-2245`
- `.tmp/cmux/Sources/App/WorkspaceRuntimeSettings.swift:13-31`
- `.tmp/cmux/Sources/App/CmuxMainWindow.swift`
