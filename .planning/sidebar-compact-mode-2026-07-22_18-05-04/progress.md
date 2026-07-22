# 执行进度：sidebar-compact-mode

- 任务 ID：`sidebar-compact-mode-2026-07-22_18-05-04`
- 创建时间：`2026-07-22_18-05-04`
- 当前状态：`ready_for_preflight`

## 已完成

- 核验 MUXY Icons rail 和 Acro 当前 Full/Hide 调用链。
- 确认既有规划已通过 PR #107 合并。
- 从最新 `origin/main` 创建 `feat/sidebar-compact-mode` worktree。
- 运行 `leaperone-dev-init`，补齐 `.planning/.gitkeep` 和 `/.worktrees/` ignore。
- 建立本任务三文件 planning，并收敛 Compact 产品范围。
- 实现 Wide、Compact、Hidden 三态真源、旧快照迁移和旧版可见性投影。
- 实现 64pt Compact 多服务器轨道、工作区稳定标识、会话角标和固定 footer。
- 第一版曾实现 Wide/Compact 主按钮互切、`⌘B` 隐藏/恢复和 Hidden 左上恢复入口；用户否决了这套分裂交互。
- 使用独立 dev PID 完成真实窗口检查，未重启正式 Acro、runtime 或 daemon。
- 重启 dev build 后确认异步布局恢复会回到 Compact；UserDefaults 同时保留 `compact` 和旧版 `leftSidebarVisible=true`。

## 进行中

- 推送、创建 PR，并执行 preflight。

## 本轮交互修正

- `⌘B`、工作台菜单、命令面板和侧栏按钮统一调用三态循环。
- 删除 `lastVisibleSidebarPresentation` 及三套隐藏/恢复方法。
- 删除 Terminal 悬浮恢复按钮，并把红黄绿留白恢复为 80pt。

## 修改文件

- `.gitignore`
- `.planning/.gitkeep`
- `.planning/sidebar-compact-mode-2026-07-22_18-05-04/task_plan.md`
- `.planning/sidebar-compact-mode-2026-07-22_18-05-04/findings.md`
- `.planning/sidebar-compact-mode-2026-07-22_18-05-04/progress.md`
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/CommandPalette.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `leaperone-dev-init --check` | 项目基线有效 | passed |
| `swift test --package-path apps/desktop-macos --filter WorkbenchLayoutStateTests` | 18 项通过；含三态循环、旧快照迁移和兼容投影 | passed |
| `swift test --package-path apps/desktop-macos --filter CompactSidebarTests` | 完整测试内 6 项通过，含最小窗口容量检查 | passed |
| `swift test --package-path apps/desktop-macos` | 57 项 XCTest + 3 项 Swift Testing 全部通过 | passed |
| `pnpm check` | protocol、runtime、mobile、cli 检查全部通过 | passed |
| `git diff --check` | 无空白错误 | passed |
| `leaperone-dev-init --check` | 项目基线有效 | passed |
| 本机 Acro 三态视觉检查 | `⌘B` 与侧栏按钮都按 Wide→Compact→Hidden→Wide 循环；Hidden 无悬浮按钮 | passed |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 规划 worktree 对应 PR 已合并 | 1 | 新建实现分支，不复用已合并分支。 |
| 项目基线检查缺两项 | 1 | 使用初始化脚本补齐，未覆盖现有项目规则。 |
| 首轮 Swift 测试找不到 `GhosttyKit/ghostty.h` | 1 | 运行仓库固定版本 `setup-ghostty.sh`，校验哈希后恢复忽略资源。 |
| 自动缩放到最小窗口时 `osascript` 缺少辅助功能权限 | 1 | 未绕过权限；保留现有 760×620 最小约束，并用真实大窗口与代码布局检查覆盖。 |
| 首次交互修正补丁未匹配 planning 清单前缀 | 1 | 补丁未产生改动；拆成代码加状态和详细 planning 两次 `apply_patch`。 |
| Computer Use 初次动作截图捕获在 180ms 过渡期间 | 1 | 等待过渡完成后重新读取窗口，确认 Hidden 已完全清除 Compact 轨道和悬浮按钮。 |
