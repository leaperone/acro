# 调研与结论：desktop-equalize-shortcut

- 任务 ID：`desktop-equalize-shortcut-2026-07-26_02-15-59`
- 创建时间：`2026-07-26_02-15-59`

## 需求事实

- 用户要求 Acro Desktop 增加 `Control + Command + =`，用于把当前 Terminal 标签页的分屏调整为相同大小，并要求对照 cmux。
- cmux 的动作 ID 是 `equalizeSplits`，默认键是 `StoredShortcut(key: "=", command: true, control: true)`。
- 本机没有 `~/.config/acro/keybindings.json`，因此修改默认值后会直接生效；已有用户 override 仍应优先。

## 真实调用链

- `AcroAppDelegate` 的本地 `keyDown` monitor 调 `ShortcutSettings.action(for:)`。
- 命中后通过 `.acroShortcutAction` 通知进入 `WorkbenchModel.perform(_:)`。
- `.equalizeSplits` 调 `WorkbenchModel.equalizeSplits()`，只修改当前 server + workspace 的 `WorkspaceTerminalLayout`。
- `WorkspaceTerminalLayout.equalizeSplits()` 调 vendored `CmuxPanes.equalizeDividerPlan()`，按同轴叶子跨度计算比例后写回布局树。
- `AcroTerminalView` 用 `ShortcutSettings.isAppShortcut` 避免终端吞掉应用快捷键。

## 调研结论

- Acro 已经有动作、菜单、命令面板、设置页、终端拦截和均分算法，不需要新增功能结构。
- 当前唯一差异是默认绑定为 `Option + Command + =`。
- 菜单快捷键、设置页默认值和终端事件路由都读取 `ShortcutStore.defaults`，修改一处即可覆盖全部入口。
- 均分算法不是把所有二叉 divider 设为 `0.5`；三列布局需要外层 `1/3`、内层 `1/2`。Acro 已复用 cmux 的正确算法，本轮不动它。

## 技术决策

| 决策 | 证据 |
|---|---|
| 把默认值从 `option: true` 改成 `control: true` | `ShortcutSettings.swift` 已有 `.equalizeSplits`，而 cmux 两代快捷键设置都使用 `Command + Control + =`。 |
| 不复制 cmux 的其他入口 | Acro 的菜单、命令面板和设置页已经共用同一动作；新增入口会造成重复真源。 |
| 不增加布局回归测试 | 本轮不改算法；`CmuxPanes` 已有同轴、跨轴和三列比例测试。 |

## 风险与边界

- 用户自定义 override 会继续覆盖默认键，这是既有且正确的行为。
- `Control + Command + =` 未与现有 `ShortcutAction` 或保留数字快捷键冲突。
- `.claude/worktrees/fix-desktop-use-full-bonsplit` 是其他任务的 dirty worktree，必须保留。
- 主 checkout 的 `.agents/skills/release/SKILL.md` 和旧 planning 目录属于无关改动，不触碰。
- Acro 的隐藏标题栏窗口没有向两套 Computer Use 暴露可用的 Accessibility/CGWindow，无法完成截图级按键前后对比；系统权限本身显示为 granted。

## 参考指针

- Acro：`apps/desktop-macos/Sources/ShortcutSettings.swift:109-177`
- Acro：`apps/desktop-macos/Sources/AcroApp.swift:19-111`
- Acro：`apps/desktop-macos/Sources/WorkbenchModel.swift:239-259,716-719`
- Acro：`apps/desktop-macos/Sources/WorkbenchLayoutState.swift:461-473`
- cmux：`.tmp/cmux/Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift:94`
- cmux：`.tmp/cmux/Sources/TabManager+EqualizeSplits.swift:5-18`
- cmux：`.tmp/cmux/cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift:66-160`
