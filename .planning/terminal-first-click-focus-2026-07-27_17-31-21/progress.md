# 执行进度：terminal-first-click-focus

- 任务 ID：`terminal-first-click-focus-2026-07-27_17-31-21`
- 创建时间：`2026-07-27_17-31-21`
- 当前状态：`delivery_ready`

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
- Acro 桌面完整测试通过：XCTest 86 项、Swift Testing 63 项。
- release 构建通过，候选 `0.0.8-beta.31` build 62 已打包。
- 热替换后 UI PID 3217、runtime PID 3231 正常，daemon PID 1151 保持不变。
- 真实 UI 已验证后台首击只激活、未聚焦 pane 首击只聚焦，均未操作 TUI。
- 最终审查提出的 press/drag/release 覆盖缺口已修复：生产代码与测试共用 `PrimaryPointerState`。
- 修复审查项后重新运行针对性 3 项测试、完整 Swift 测试和 release 构建，全部通过。

## 进行中

- PR 合并与 Beta.31 发布。

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
| Acro 桌面完整测试 | XCTest 86 项、Swift Testing 63 项 | 通过 |
| release 构建 | `swift build -c release` | 通过 |
| 候选包 | `0.0.8-beta.31` build 62 | 通过 |
| 真实 UI | 后台首击只激活；未聚焦 pane 首击只聚焦；TUI prompt 未变化 | 通过 |
| 会话保持 | UI/runtime 热替换后 daemon PID 1151 未变化 | 通过 |
| 最终状态机测试 | focus-only 事件序列为空；已聚焦手势为 press → drag → release | 通过 |
| 修复审查项后完整测试 | XCTest 86 项、Swift Testing 63 项 | 通过 |
| 修复审查项后 release 构建 | `swift build -c release` | 通过；仅仓库既有 Swift 6 actor warning |
| pnpm check / build | 全部 workspace 通过 | 通过；仅仓库既有 esbuild `import.meta` warning |
| origin/main 合并探测 | `git merge-tree --write-tree HEAD origin/main` | 通过，无冲突 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 1 | 无需恢复 |
