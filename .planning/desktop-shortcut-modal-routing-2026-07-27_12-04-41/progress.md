# 执行进度：desktop-shortcut-modal-routing

- 任务 ID：`desktop-shortcut-modal-routing-2026-07-27_12-04-41`
- 创建时间：`2026-07-27_12-04-41`
- 当前状态：`complete`

## 已完成

- 完成 Acro 全局监听器、模型通知、命令面板和全部弹层入口审计。
- 对照 cmux 的 presentation-aware shortcut routing 与反例。
- 创建独立 worktree 并校验项目基线。
- 完成三态路由、模型与 AppKit 统一展示态 guard、命令面板编辑键保留。
- 针对性快捷键测试首次运行 9 项通过；补充 Sheet 覆盖后发现 `NSApp` 在测试进程未初始化，已改用 `NSApplication.shared`。
- 完成全部调用方与 cmux 反例复核，未发现剩余 correctness 问题。
- 完成 Desktop 全量测试、release build、全仓 TypeScript 检查与构建。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-shortcut-modal-routing-2026-07-27_12-04-41/*`
- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Sources/ShortcutSettings.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/ShortcutSettingsTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 调用链审计 | 全局 monitor 在弹层前执行且无 presentation context | 已确认根因 |
| `swift test --filter ShortcutSettingsTests` | 初版 9 项通过 | 通过 |
| 补充 Sheet 覆盖后的针对性测试 | `NSApp` 未初始化导致模型测试崩溃 | 已修复并通过重跑 |
| `swift test --filter ShortcutSettingsTests` | 9 项通过 | 通过 |
| `swift test` | 87 XCTest + 48 Swift Testing，共 135 项通过 | 通过 |
| `swift build -c release` | 完成；仅有既有 Vendor/Updater 警告 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | runtime/cli 完成；仅有既有 `import.meta` CJS 警告 | 通过 |
| `git diff --check` | 无错误 | 通过 |
| 最终只读 correctness 审查 | 未发现 P0/P1/P2 问题 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Swift Package 测试中 `NSApp` 为 nil | 1 | 改用 `NSApplication.shared`，针对性与全量测试通过 |
