# 执行进度：terminal-first-click-focus

- 任务 ID：`terminal-first-click-focus-2026-07-27_17-31-21`
- 创建时间：`2026-07-27_17-31-21`
- 当前状态：`in_progress`

## 已完成

- 对照 Acro 与 cmux 的 inactive-window 和 inactive-pane 左键语义。
- 确认 Acro 无条件转发、cmux 默认安全且未聚焦 pane 只聚焦。
- 搜索 Acro 全部 `acceptsFirstMouse`、终端鼠标转发、pane focus 和现有测试调用链。
- 创建独立 worktree `fix/terminal-first-click-focus` 并校验项目基线。
- 新增终端正文不接受 inactive-window first mouse 的回归测试，并在旧实现确认失败。
- 终端正文恢复 AppKit 默认 first-mouse 行为，后台窗口首击只激活。
- `TerminalPanesView` 向缓存终端传入实时 pane focused 查询。
- 左键在 pointer-down 前快照焦点；未聚焦 pane 只完成 focus，不向 Ghostty 发送 press。
- focus-only 点击不建立 pending release，左键拖动只在已有 press 时转发。

## 进行中

- 运行完整桌面测试、release 构建和真实双窗口 UI 验收。

## 修改文件

- `.planning/terminal-first-click-focus-2026-07-27_17-31-21/`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Sources/AcroTerminalView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro / cmux 源码对照 | 确认默认 first mouse 与未聚焦 pane 转发差异 | 通过 |
| 当前 Git 状态 | worktree 基于 `809a0f1`，仅本任务 planning 未跟踪 | 通过 |
| first-mouse 红测 | `acceptsFirstMouse` 仍为 true，断言失败 | 符合预期 |
| 针对性终端点击测试 | first mouse、focus-only policy、pane focus 3 项通过 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| | 1 | |
