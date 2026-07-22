# 调研与结论：sidebar-compact-mode

- 任务 ID：`sidebar-compact-mode-2026-07-22_18-05-04`
- 创建时间：`2026-07-22_18-05-04`

## 需求事实

- 用户要求参考 MUXY 的 Compact 侧边栏，为 Acro 在现有 Full/Hide 之间增加 Compact。
- MUXY 源码实际命名为 `Icons`：默认 collapsed 为 44pt Icons，expanded 为 220pt Wide；图标行显示 Logo、SF Symbol 或首字母，并叠加活动状态。
- 用户接受的 Acro 方案是三态：Wide、Compact、Hidden；Compact 负责导航，不承担结构管理。
- 用户否决 Hidden 时浮在 Terminal 左上角的恢复按钮，并要求 `⌘B` 在三种模式间切换。

## 真实调用链

- `WorkbenchModel.leftSidebarVisible` 是当前显示/隐藏真源；快捷键、命令面板和布局恢复都直接改这个布尔值。
- `WorkbenchLayoutSnapshot.leftSidebarVisible` 持久化布尔值，当前解码要求字段存在。
- `WorkbenchView` 根据布尔值决定是否渲染 `SidebarView`，Wide 宽度由 `acro.sidebar.width` 保存并限制为 180–420pt。
- `SidebarView` 同时展示所有 RuntimeHub 服务器，并按服务器、分组、工作区、会话构建完整树。
- `TerminalPanesView` 在左侧栏隐藏时只需保留原有 80pt 红黄绿空间，不应承载侧栏控制。
- Workspace 点击动作已经统一为 `activate(serverId:)` 后 `selectWorkspace(_:)`，Compact 可以复用，无需增加 Runtime API。

## 调研结论

- 根因是展示状态只有布尔值。应先把状态真源升级为三态，再让布局和入口消费它。
- 第一版又为三种入口分别实现隐藏/恢复、宽/窄互切和悬浮恢复，造成同一快捷键和按钮语义不一致。根因应在统一状态转换方法中修正。
- Compact 不能复用缩窄后的 Wide：Wide 的 Header、路径、副行、拖拽、会话树和管理菜单都不适合 64pt。
- 多服务器是 Acro 与 MUXY 的核心差异。Compact 必须保留服务器分段和连接状态，不能只显示当前服务器工作区。
- Compact 始终显示 Workspace。会话切换继续由中央标签栏承担，`sidebarViewMode == sessions` 只影响 Wide。
- Hidden 不增加工作区内控件；`⌘B`、macOS 工作台菜单和命令面板已经是足够的恢复入口。

## 技术决策

| 决策 | 证据 |
|---|---|
| `LeftSidebarPresentation: wide/compact/hidden` | 当前所有入口只依赖一个布尔值；显式枚举可以集中迁移和切换规则。 |
| `next` 固定为 Wide → Compact → Hidden → Wide | 快捷键、侧栏按钮和命令面板只调用一个转换，删除上次可见状态。 |
| 快照继续编码 `leftSidebarVisible` | 旧客户端忽略新增字段但仍能读取可见性；Compact 对旧客户端投影为可见。 |
| Compact 64pt | 现有 Header 为红黄绿保留 62pt，44pt 会要求重做标题栏覆盖布局。 |
| Stable ID 派生颜色 | 首字符可能重复；Workspace 模型没有图标颜色字段，且 Swift `hashValue` 跨进程不稳定。 |
| 不新增 `⌘⇧B` | 用户要求的是 Compact 能力；现有 `⌘B` 加侧栏按钮和菜单已覆盖三态。 |

## 风险与边界

- 旧快照缺少新字段时必须从 `leftSidebarVisible` 无损迁移。
- 旧 `leftSidebarVisible` 快照仍需迁移；新快照继续写兼容布尔投影。
- Compact 的服务器和工作区 ID 可能重名，选中态必须同时比较 serverId 和 workspaceId。
- 大量工作区必须使用 ScrollViewReader 保证选中项可见，并避免固定 footer 被卷走。
- 颜色、角标和首字符不能替代完整无障碍标签与悬停说明。
- 使用 `.equatable()` 的 Compact 叶子行必须把连接可用性放入快照，否则断线重连后按钮禁用态会被旧快照错误复用。
- 760pt 最小窗口下，默认 Wide 内容宽度为 512pt、Compact 为 696pt，均低于 720pt 右侧栏阈值并保留至少 440pt 终端；Hidden 为 760pt，可同时容纳 440pt 终端和 260pt 右侧栏。

## 参考指针

- `.planning/sidebar-three-state/plan.md`
- `.tmp/muxy/Muxy/Models/UI/SidebarMode.swift`
- `.tmp/muxy/Muxy/Views/Layouts/ProjectFocused/ProjectFocusedSidebar.swift`
- `.tmp/muxy/Muxy/Views/Layouts/ProjectFocused/ProjectRow.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`

## 最终交互验证

- MUXY 的真源仍是一个 `sidebarExpanded` 布尔值；Collapsed Style 可配置 Hidden/Icons，Expanded Style 可配置 Icons/Wide，默认只在 Icons 与 Wide 两端切换。Acro 没有照搬这组设置，而是把用户需要的三个状态做成显式循环。
- dev 窗口从 Compact 按 `⌘B` 进入 Hidden，再按 `⌘B` 进入 Wide；Wide 和 Compact 底部的侧栏按钮也分别进入下一个状态。
- Hidden 截图和无障碍树都确认 Terminal 顶部没有侧栏按钮；只保留系统窗口控制区、标签条和原有内容。
- 真实检查使用独立裸 `AcroDesktop` 进程；正式 `/Applications/Acro.app`、runtime 和 daemon PID 在检查前后保持不变。
