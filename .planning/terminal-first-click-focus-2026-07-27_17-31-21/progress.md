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

## 进行中

- 实现 pointer-down 前焦点快照、focus-only 左键和拖动配对保护。

## 修改文件

- `.planning/terminal-first-click-focus-2026-07-27_17-31-21/`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro / cmux 源码对照 | 确认默认 first mouse 与未聚焦 pane 转发差异 | 通过 |
| 当前 Git 状态 | worktree 基于 `809a0f1`，仅本任务 planning 未跟踪 | 通过 |
| first-mouse 红测 | `acceptsFirstMouse` 仍为 true，断言失败 | 符合预期 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| | 1 | |
