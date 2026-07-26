# 执行进度：desktop-top-tab-chrome

- 任务 ID：`desktop-top-tab-chrome-2026-07-27_05-39-08`
- 创建时间：`2026-07-27_05-39-08`
- 当前状态：`complete`

## 已完成

- 更新并确认 cmux reference 已在 `aac23518`。
- 对比 Acro 与 cmux vendored Bonsplit，相关文件完全一致。
- 追踪真实重排、布局持久化、标题栏 safe area 和 presentation mode 调用链。
- 新增启动模式回归：当前 Acro 初始化后 key 仍为 nil，按预期失败。
- 新增真实窗口顶边断言；当前 main 已贴顶。
- 将真实重排测试固定到 minimal 模式，仍可重排并持久化。
- Desktop CI 已按预期红色，唯一失败为启动后 `workspacePresentationMode` 仍是 nil。
- 在 `AcroApp.init()` 构造 Workbench/Bonsplit 前固定写入 minimal presentation。
- 启动模式和真实窗口拖拽两项针对性测试转绿。
- 在最新 `origin/main` 上完成全量 Desktop、TypeScript 和打包脚本验证。
- 交付审查发现新增测试共享 `UserDefaults.standard`，将 AppKit 交互 suite 串行化，避免并发恢复 presentation key 产生随机失败。
- 独立代码审查无问题，与最新 main 合并探测无冲突，PR #131 最终代码 CI 全绿。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-top-tab-chrome-2026-07-27_05-39-08/*`
- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| cmux reference pull | 已是最新 `aac23518` | 已通过 |
| Bonsplit vendor 比较 | TabBarView、TabItemView、TabBarMetrics 逐字一致 | 已确认 |
| 当前中心点拖拽测试 | 真实 `NSWindow + NSEvent` 可重排并持久化 | 已有证据 |
| Computer Use | Orca runtime 未运行 | 未做真实 UI 验证 |
| 启动模式回归 | 期望 minimal，实际 nil | 红色测试 |
| 真实窗口顶边 + minimal 拖拽 | 通过 | 已通过 |
| PR #131 Desktop CI | `appBootstrapsMinimalBonsplitPresentation` 失败，实际 nil | 红色证据 |
| 启动模式针对性测试 | 1 项通过，初始化后为 minimal | 已通过 |
| minimal 真实窗口拖拽 | 1 项通过，贴顶、重排、持久化均成立 | 已通过 |
| 全量 Desktop | 80 XCTest + 24 Swift Testing | 已通过 |
| `pnpm check` | TypeScript 与 15 项 Node 测试 | 已通过 |
| `pnpm build` | CLI/runtime 构建；仅现有 import.meta 警告 | 已通过 |
| Desktop release scripts | 7 项通过 | 已通过 |
| Base merge probe | 与最新 `origin/main` 无冲突 | 已通过 |
| 独立代码审查 | 无 critical/high/medium/low 问题 | 已通过 |
| PR #131 CI | TypeScript、desktop-macos 全绿 | 已通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Orca Computer Use `runtime_unavailable` | 1 | 按仓库规则停止重试，改用可重复窗口测试 |
| GhosttyKit `ghostty.h` 缺失 | 1 | 运行项目 setup 脚本补齐 worktree 构建资产 |
| 顶部 2pt 合成拖拽测试挂起 | 1 | 终止测试；分离顶边几何与中心拖拽，避免把 AppKit 合成事件限制当真实行为 |
| 新增测试并发修改同一 AppStorage key | 1 | 将共享 AppKit/UserDefaults 的交互 suite 标记为 serialized |
