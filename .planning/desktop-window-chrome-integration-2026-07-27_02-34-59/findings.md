# 调研与结论：desktop-window-chrome-integration

- 任务 ID：`desktop-window-chrome-integration-2026-07-27_02-34-59`
- 创建时间：`2026-07-27_02-34-59`

## 需求事实

- 用户认为 beta.19 顶部标签栏的 UIUX 仍明显弱于 cmux，并要求持续 review/debug/improve。
- 当前运行实例是 beta.19 build 50；只有一个 UI、一个 runtime 和一个持久 daemon。
- Orca Computer Use runtime 未运行；macOS 能枚举 Acro 窗口，但系统拒绝窗口像素捕获。

## 真实调用链

- `AcroApp` 使用 `.hiddenTitleBar`，`WindowConfigurator` 设置 full-size transparent titlebar 且 `window.isMovable = false`；`WindowDragHandle` 仍被 wide/compact 侧栏标题区使用，但终端顶部已无调用方。
- `Bonsplit.TabBarView` 通过 `@AppStorage("workspacePresentationMode")` 判断 minimal；minimal 才在空白 chrome 调用 `performDrag`，并让 action lane 仅悬停显示。
- Acro 从未写入该 key，默认保持 `standard`；旧 `WindowDragHandle` 已没有调用方。
- `WorkbenchModel.synchronizeTerminalPaneControllers()` 目前只用 `leftSidebarPresentation == .hidden` 决定 80pt inset，没有全屏条件。

## 调研结论

- Acro 与当前 cmux reference 的 Bonsplit 标签核心文件逐字节一致，重排、滚动、selected reveal、hover/close 与 drop 算法不是差异来源。
- 功能缺失来自 host 窗口 chrome 状态未接入：空白拖窗断路，action lane 常驻，全屏可能留下 80pt 死区。
- cmux 同样使用 28pt tab bar 和 80pt traffic-light inset，但只在 minimal、侧栏隐藏、非全屏时启用。
- 真实运行证明：直接写全局 minimal 会在 Acro 顶部产生额外空区；即使拆成独立 hover/drag 配置，用户仍观察到空区。说明当前缺少的不是单一布尔开关，必须先拿到当前窗口的像素位置证据。

## 技术决策

| 决策 | 证据 |
|---|---|
| 只修 Acro host 接入层 | Bonsplit 四个标签核心文件与 cmux SHA-256 一致 |
| 不改 `workspacePresentationMode` | 两次真实窗口验证证明 Bonsplit 模式开关不能消除宿主 safe area，且会引入新的顶部布局变化 |
| 只抵消终端区域实际占用的标题栏 safe area | cmux 使用 `-min(nativeTitlebarHeight, hostingSafeAreaTop)`；该公式能适配不同窗口标题栏高度 |
| 全屏补偿固定为 0 | 全屏没有原生标题栏，继续负 padding 会把内容推出窗口 |
| 保留侧栏专用 `WindowDragHandle` | 左侧栏标题行仍需要原有拖窗区域，本轮只移动终端与右栏 |

## 风险与边界

- 不把 cmux 的整套主题、浏览器按钮或配置系统搬入 Acro。
- Computer Use 无法捕获窗口像素；最终改用 LLDB 读取真实 AppKit frame，不把源码和测试冒充视觉验收。
- 两次错误尝试均已撤回；当前分支只保留宿主 safe-area 根因修复。
- 用户提供的原始窗口截图显示：左侧栏标题行正常占用红绿灯区域，但终端与右侧区域整体从该行下方开始，形成约 32pt 的整行空区。它是宿主窗口/HSplitView 安全区，不是 Bonsplit 标签内部间距。
- cmux 对同一类 `WindowGroup` 问题使用 `effectiveTitlebarPadding`：普通窗口取 `-min(nativeTitlebarHeight, contentView.safeAreaInsets.top)`，全屏为 0；只作用于 terminal content。
- `.tmp/cmux` 当前 HEAD 可能落后远端，因为本机 DNS 暂不可用；相关 Bonsplit 文件已与 Acro vendor 逐字节核对。

## 参考指针

- Acro：`TerminalPaneController.swift:50-52,273-300`、`WorkbenchModel.swift:513-535`、`WorkbenchView.swift:343-352`。
- Bonsplit：`TabBarView.swift:802-910,2253-2396`。
- cmux reference：`ContentView.swift:2209-2215`、`TabManager.swift:1018-1043`、`WindowDragHandleView.swift:576-607`。
