# 执行进度：terminal-tab-interactions

- 任务 ID：`terminal-tab-interactions-2026-07-27_13-38-30`
- 创建时间：`2026-07-27_13-38-30`
- 当前状态：`in_progress`

## 已完成

- 核对主仓状态、历史提交、当前 Beta 和运行进程。
- 对照 Acro 与 cmux/Bonsplit 的标签选择、拖拽和分屏调用链。
- 运行现有 TerminalPanesInteractionTests：43 项通过。
- 确认按钮视觉槽内的合法点击修复前失败、修复后通过。
- 确认全尺寸隐藏标题栏窗口的根宿主修复前仍保留 32pt top safe area。

## 进行中

- 删除负 top padding 补偿，改为在现有 AppKit 内容宿主上取消顶部 safe area。
- 执行全量验证、Git 与 Beta 发布收敛。

## 修改文件

- `.planning/terminal-tab-interactions-2026-07-27_13-38-30/*`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| TerminalPanesInteractionTests | 43 项通过；缺少点击和按钮命中覆盖 | pass |
| 新增真实窗口回归 | 修复前失败，修复后通过 | pass |
| 全尺寸标题栏根 safe area 回归 | 修复前 32pt，修复后 0pt | pass |
| 旧全量验证与本机包 | 新窗口根因出现后已失效，必须重跑 | pending |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 测试输出先显示 XCTest 0 项 | 1 | Swift Testing 随后执行 43 项，筛选有效 |
| 新 worktree 缺 Ghostty header | 1 | 运行仓库固定版本 `setup-ghostty.sh` 后恢复构建 |
