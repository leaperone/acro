# 执行进度：inactive-titlebar-first-mouse

- 任务 ID：`inactive-titlebar-first-mouse-2026-07-27_16-37-41`
- 创建时间：`2026-07-27_16-37-41`
- 当前状态：`in_progress`

## 已完成

- 对照 Acro 与 cmux 的 first-mouse 设计，确认顶部交互与正文必须分区处理。
- 搜索标签、关闭、分屏、标签空白拖窗、侧栏拖窗和终端正文的真实命中路径。
- 创建并校验独立 worktree `fix/inactive-titlebar-first-mouse`。

## 进行中

- 实现标签栏共享 first-mouse 边界和两个原生拖窗视图的首次手势支持。

## 修改文件

- `apps/desktop-macos/Vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `.planning/inactive-titlebar-first-mouse-2026-07-27_16-37-41/`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro / cmux 源码对照 | 确认共享区域 registry 是最小根修入口 | 通过 |
| Git 状态 | worktree 基于 `516d330`，仅本任务 planning 未跟踪 | 通过 |
| Bonsplit first-mouse 红测 | hosting view 与 drag zone 两项断言均失败 | 符合预期 |
| Acro first-mouse 红测 | `WindowDragNSView.acceptsFirstMouse` 断言失败 | 符合预期 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| | 1 | |
