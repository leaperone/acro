# 执行进度：terminal-tab-interactions

- 任务 ID：`terminal-tab-interactions-2026-07-27_13-38-30`
- 创建时间：`2026-07-27_13-38-30`
- 当前状态：`completed`

## 已完成

- 核对主仓状态、历史提交、当前 Beta 和运行进程。
- 对照 Acro 与 cmux/Bonsplit 的标签选择、拖拽和分屏调用链。
- 运行现有 TerminalPanesInteractionTests：43 项通过。
- 确认按钮视觉槽内的合法点击修复前失败、修复后通过。
- 确认全尺寸隐藏标题栏窗口的根宿主修复前仍保留 32pt top safe area。
- 确认异步配置修复前首个 layout 仍保留 32pt；同步配置后首帧为 0pt。

## 进行中

- 无。

## 修改文件

- `.planning/terminal-tab-interactions-2026-07-27_13-38-30/*`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| TerminalPanesInteractionTests | 43 项通过；覆盖首次 layout、resize、标签点击、同窗格重排和分屏按钮命中 | pass |
| 新增真实窗口回归 | 修复前失败，修复后通过 | pass |
| 全尺寸标题栏根 safe area 回归 | 修复前 32pt，修复后 0pt | pass |
| 首帧根 safe area 回归 | 异步修复前首个 layout 为 32pt，同步修复后为 0pt | pass |
| Acro Desktop 完整测试 | 86 个 XCTest + 56 个 Swift Testing 全部通过 | pass |
| Bonsplit 完整测试 | 204 项通过 | pass |
| Swift release build | 通过；仅既有 Swift 6 actor warning | pass |
| pnpm check | 通过 | pass |
| pnpm build | 通过；仅既有 `import.meta` warning | pass |
| 最终只读审查 | Critical / High / Medium 均为 0；保留 fullscreen 自动化覆盖缺口 | pass |
| 真实 UI / XCUITest | Orca runtime 不可用，未执行 | not_run |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 测试输出先显示 XCTest 0 项 | 1 | Swift Testing 随后执行 43 项，筛选有效 |
| 新 worktree 缺 Ghostty header | 1 | 运行仓库固定版本 `setup-ghostty.sh` 后恢复构建 |
