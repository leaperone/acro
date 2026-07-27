# 执行进度：terminal-tab-interactions

- 任务 ID：`terminal-tab-interactions-2026-07-27_13-38-30`
- 创建时间：`2026-07-27_13-38-30`
- 当前状态：`completed`

## 已完成

- 核对主仓状态、历史提交、当前 Beta 和运行进程。
- 对照 Acro 与 cmux/Bonsplit 的标签选择、拖拽和分屏调用链。
- 运行现有 TerminalPanesInteractionTests：43 项通过。

## 进行中

- 无。

## 修改文件

- `.planning/terminal-tab-interactions-2026-07-27_13-38-30/*`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| TerminalPanesInteractionTests | 43 项通过；缺少点击和按钮命中覆盖 | pass |
| 新增真实窗口回归 | 修复前失败，修复后通过 | pass |
| Acro Desktop 完整测试 | 全部通过 | pass |
| Bonsplit 完整测试 | 204 项通过 | pass |
| pnpm check | 通过 | pass |
| pnpm build | 通过；仅既有 `import.meta` warning | pass |
| Release package | `0.0.8-beta.27` / Build 58 本地包成功 | pass |
| 本机热替换 | UI/runtime 已更新；daemon PID 1151 保持，8790 health 正常 | pass |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 测试输出先显示 XCTest 0 项 | 1 | Swift Testing 随后执行 43 项，筛选有效 |
| 新 worktree 缺 Ghostty header | 1 | 运行仓库固定版本 `setup-ghostty.sh` 后恢复构建 |
