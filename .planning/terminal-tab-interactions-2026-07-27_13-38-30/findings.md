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

## 技术决策

| 决策 | 证据 |
|---|---|
| 先补真实点击与按钮事件测试 | 直接覆盖用户复现，避免 controller API 绿灯掩盖 hit-testing 回归 |
| 不新增自定义拖拽实现 | cmux/Bonsplit 已完整提供所需能力 |

## 风险与边界

- AppKit/SwiftUI 的 hit-testing 与窗口拖动语义可能只在真实窗口层级出现，测试必须使用生产 `WorkbenchView` 和窗口配置。
- 当前未做 Computer Use；最终需明确自动化验证边界。

## 参考指针

- `cfb19a7`、`a719d8c`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `.tmp/cmux/Sources/WorkspaceContentView.swift`
