# 任务计划：sidebar-compact-mode

- 任务 ID：`sidebar-compact-mode-2026-07-22_18-05-04`
- 创建时间：`2026-07-22_18-05-04`

## 目标

为 Acro macOS 桌面端实现明确的 `wide`、`compact`、`hidden` 左侧栏三态。Compact 以固定 64pt 图标轨道保留多服务器和工作区快速切换，Hidden 完全释放终端空间。

## 范围

- [x] 用三态值替代 `leftSidebarVisible` 作为桌面端内部真源。
- [x] 保留旧快照的 `leftSidebarVisible` 兼容投影，并迁移旧数据。
- [x] 新增 Compact 独立视图，投影服务器、分组顺序、工作区和会话数量。
- [x] Wide 保留现有完整管理能力和 180–420pt 用户宽度。
- [x] `⌘B`、工作台菜单、命令面板和侧栏按钮统一按 Wide → Compact → Hidden → Wide 循环。
- [x] 删除 Terminal 上的悬浮恢复按钮，Hidden 通过 `⌘B`、工作台菜单或命令面板继续切换。
- [x] 菜单仍可直达三态，并完成相关文案、测试和真实窗口验证。

## 非目标

- 不修改 Runtime、daemon、协议 schema 或移动端。
- 不给 Workspace 或 Server 增加持久化图标、颜色或缩写字段。
- 不在 Compact 中复制会话树、分组名称、路径、拖拽整理或破坏性管理操作。
- 不增加第二个侧栏快捷键，也不为三个状态分别扩张命令面板命令。
- 不重做现有 Wide 视觉样式或右侧栏。

## 关键约束

- `.tmp/muxy` 只读，只参考其 44pt Icons rail、项目图标、活动角标和纵向 footer。
- Acro 左侧栏承载 62pt 窗口控制区，因此 Compact 固定为 64pt。
- Compact 行遵守现有 snapshot 边界：叶子行只接收不可变值和动作闭包。
- 工作区颜色只从稳定 ID 本地推导，不能使用每次进程随机的 `hashValue`。
- 所有主入口必须调用同一个循环方法；使用无回弹的短宽度过渡，减少动态效果时取消位移动画。
- 保留现有 `.agents/skills/release/SKILL.md` 等主 checkout 无关改动，不跨 worktree 修改。

## 修改路径

- `.planning/sidebar-compact-mode-2026-07-22_18-05-04/{task_plan,findings,progress}.md`
- `.gitignore`、`.planning/.gitkeep`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/CommandPalette.swift`
- `apps/desktop-macos/Sources/ShortcutSettings.swift`
- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`

## 验证方式

- `swift test --package-path apps/desktop-macos`
- `pnpm check`
- `git diff --check`
- 运行本机 Acro dev app，核验 Wide、Compact、Hidden、滚动、统一循环、无 Terminal 悬浮按钮和重启恢复；用布局常量测试覆盖最小窗口，用代码检查覆盖三态菜单与减少动态效果。
- preflight 的构建、冲突、领域检查和代码审查全部通过。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成 Git 收尾准备

## 决策

| 决策 | 理由 |
|---|---|
| 使用显式三态枚举 | 布尔值无法表达 Compact；比 MUXY 的布尔值加两组样式设置更直接。 |
| `⌘B`、工作台菜单、命令面板和侧栏按钮统一三态循环 | 三套入口只保留一个状态转换，行为一致且可预测。 |
| Hidden 不显示 Terminal 悬浮按钮 | 用户明确否决该视觉；快捷键、原生菜单和命令面板已经提供恢复路径。 |
| Compact 使用独立视图 | 当前 Wide 包含管理、拖拽和会话树，强行压缩会制造大量条件分支。 |
| Workspace 使用首字符、稳定颜色和会话角标 | Acro 没有 MUXY 的项目 Logo/颜色字段，但紧凑轨道仍需可辨识性。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 既有 `plan/sidebar-three-state` 已通过 PR #107 合并 | 1 | 保留原 worktree，从最新 `origin/main` 新建 `feat/sidebar-compact-mode`。 |
| 仓库基线缺少 `.planning/.gitkeep` 和 `/.worktrees/` ignore | 1 | 由 `leaperone-dev-init` 幂等补齐并纳入本任务。 |
