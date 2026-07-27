# 调研与结论：terminal-tab-interactions

- 任务 ID：`terminal-tab-interactions-2026-07-27_13-38-30`
- 创建时间：`2026-07-27_13-38-30`

## 需求事实

- Beta.17 的自定义半标签 drop zone 破坏了旧自定义标签条；Beta.19 起 Acro 已整体采用 cmux 的 Bonsplit UI。
- 当前 Beta.26 仍被用户复现：标签点击、完整拖拽链和右侧分屏按钮失效。

## 真实调用链

- `TerminalPanesView` 直接渲染 `BonsplitView`。
- `TerminalPaneController` 是唯一 Bonsplit delegate，负责选择、移动、分屏、新建和布局持久化。
- `TabItemView.onTapGesture` 调用 Bonsplit `selectTab`；右侧按钮调用 `splitPane` 或 `requestNewTab`；拖拽由 Bonsplit 的 geometry registry、manual reorder tracker 和 pane drop delegate 处理。

## 调研结论

- Acro vendored Bonsplit 与 `.tmp/cmux/vendor/bonsplit` 的交互代码基本一致；Acro 差异主要是受支持右键菜单过滤。
- 现有 43 项 TerminalPanes 测试通过，其中真实鼠标拖拽测试只证明排序结果；没有普通点击和右侧按钮真实命中测试。
- `/Applications/Acro.app` 是 Beta.25 Build 56；主分支已前进到 Beta.26。
- 普通 `NSWindow` 行为测试只能证明 Bonsplit action 与窗口级拖拽监听器可执行，不能排除正式 `.hiddenTitleBar` Scene 的宿主层吞事件。
- 右侧按钮栏每项布局预留 22pt，但普通 SwiftUI `Button` 和 mouse-down 自定义按钮都只让图标本身命中。900pt fixture 中点击 `splitRight` 槽中心左侧 5pt 无效，而移动 5pt 到图标中心才生效。
- 给两类按钮 label 统一设置 22×tabBarHeight frame 后，同一真实点击测试通过；根因是视觉槽位和命中区域不一致。
- 正式窗口使用 SwiftUI `WindowGroup(.hiddenTitleBar)`，Acro 又用负 top padding 抵消 32pt safe area；这只移动视觉内容，没有消除根 `NSHostingView` 的有效安全区。
- 将回归窗口按 `.fullSizeContentView`、隐藏透明标题栏创建后，生产 `WorkbenchView` 的根宿主仍报告 32pt top safe area，失败测试稳定复现。
- cmux 使用零 safe-area 的 `MainWindowHostingView`。Acro 可复用 AppKit 原生 `additionalSafeAreaInsets` 在现有窗口宿主上取消同一安全区，不需要重写 Bonsplit 或迁移整个 App 生命周期。

## 技术决策

| 决策 | 证据 |
|---|---|
| 先补真实点击与按钮事件测试 | 直接覆盖用户复现，避免 controller API 绿灯掩盖 hit-testing 回归 |
| 不新增自定义拖拽实现 | cmux/Bonsplit 已完整提供所需能力 |
| 只扩大现有按钮 label，不改分屏 action/delegate | 分屏逻辑可直接执行；失败发生在 action 前的命中层 |
| 删除负 padding，直接取消根宿主 safe area | 根修窗口层级，避免视觉位置与命中层级分离；改动小于重建 programmatic NSWindow |

## 风险与边界

- AppKit/SwiftUI 的 hit-testing 与窗口拖动语义可能只在真实 Scene 层级出现；当前自动化使用生产 `WorkbenchView` 与全尺寸标题栏窗口，但不等同于 XCUITest。
- 当前未做 Computer Use；最终需明确自动化验证边界。

## 参考指针

- `cfb19a7`、`a719d8c`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `.tmp/cmux/Sources/WorkspaceContentView.swift`
