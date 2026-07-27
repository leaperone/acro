# 执行进度：inactive-titlebar-first-mouse

- 任务 ID：`inactive-titlebar-first-mouse-2026-07-27_16-37-41`
- 创建时间：`2026-07-27_16-37-41`
- 当前状态：`in_progress`

## 已完成

- 对照 Acro 与 cmux 的 first-mouse 设计，确认顶部交互与正文必须分区处理。
- 搜索标签、关闭、分屏、标签空白拖窗、侧栏拖窗和终端正文的真实命中路径。
- 创建并校验独立 worktree `fix/inactive-titlebar-first-mouse`。
- 在旧实现上确认三项 first-mouse 回归断言失败，并单独提交红测。
- 让 pane hosting view 只在现有标签栏 registry 命中时接受 first mouse。
- 让 Bonsplit 标签栏背景、空白拖窗区和 Acro 侧栏拖窗区接受第一次鼠标操作。

## 进行中

- 运行完整桌面测试、release 构建和真实双窗口 UI 验收。

## 修改文件

- `apps/desktop-macos/Vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `.planning/inactive-titlebar-first-mouse-2026-07-27_16-37-41/`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro / cmux 源码对照 | 确认共享区域 registry 是最小根修入口 | 通过 |
| Git 状态 | worktree 基于 `516d330`，仅本任务 planning 未跟踪 | 通过 |
| Bonsplit first-mouse 红测 | hosting view 与 drag zone 两项断言均失败 | 符合预期 |
| Acro first-mouse 红测 | `WindowDragNSView.acceptsFirstMouse` 断言失败 | 符合预期 |
| Bonsplit 针对性测试 | 2 项通过 | 通过 |
| Acro 针对性测试 | 标签点击/拖拽/分屏与原生拖窗 2 项通过 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| | 1 | |
