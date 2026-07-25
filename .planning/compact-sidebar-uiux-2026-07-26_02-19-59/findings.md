# 调研与结论：compact-sidebar-uiux

- 任务 ID：`compact-sidebar-uiux-2026-07-26_02-19-59`
- 创建时间：`2026-07-26_02-19-59`

## 需求事实

- 仓库没有 `Impact Mode`；结合当前桌面端功能和用户的 `sidebard` 表达，默认将目标解释为 Compact 左侧栏。
- Compact 是 64pt 宽的服务器 / Workspace 快速切换轨道，不承担 Wide 中的结构管理。
- 当前安装版本是 `0.0.8-beta.13 (43)`，已包含 Compact 初版。

## 真实调用链

- `⌘B`、工作台菜单、命令面板和侧栏底部按钮最终都调用 `WorkbenchModel.cycleLeftSidebarPresentation()`。
- `WorkbenchView` 按 `leftSidebarPresentation` 渲染 `SidebarView`、`CompactSidebarView` 或隐藏左侧栏。
- Compact 从 `RuntimeHub.entries` 读取每台服务器，通过 `CompactSidebarProjection` 保留 Workspace 分组顺序，然后渲染服务器和 Workspace 按钮。
- Workspace 选中变化和列表变化都调用 `scrollToSelection`；当前实现强制居中并执行 180ms 动画。

## 调研结论

- 强制 `anchor: .center` 会让已经可见的 Workspace 也跳到中央；它是 Compact 轨道不稳定的直接原因。
- 数据投影保留了分组，但界面只用 6pt 额外空白表示后续分组，重复首字母时难以辨认边界。
- Compact 底部的“新建工作区”和“连接服务器”都以加号为主体；Wide 已有更明确的 Workspace 图标可复用。
- 按钮可见选中态没有映射为 `.isSelected` 无障碍 trait，VoiceOver 无法读出当前服务器和 Workspace。
- 服务器状态只用 7pt 绿 / 橙 / 灰实心点区分，色弱用户缺少第二视觉线索。
- Compact 底部四个图标按钮的 label 是 22×22，明显小于中间导航项的 52×44 命中区；共享 `SidebarFooterIconButtonStyle` 没有补齐点击范围。
- Compact 强制隐藏滚动条，长列表没有溢出和当前位置反馈。
- 真实像素检查被本机辅助功能和屏幕录制权限阻断；已有窗口可见，但本轮不能获取可信截图或无障碍树。

## 技术决策

| 决策 | 证据 |
|---|---|
| `scrollTo` 不传 anchor，不加动画 | 默认滚动保证目标可见，避免高频键盘导航的延迟和整列跳动。 |
| 后续 Workspace 分组前显示短分隔线 | 保留 64pt 宽度和紧凑性，同时让已有分组结构可见。 |
| 复用 `square.stack.3d.up.badge.plus` | 该 SF Symbol 已在 Wide 侧边栏使用，无需猜测新图标或增加资源。 |
| 在 Compact 共享 ButtonStyle 映射 `.isSelected` | 服务器和 Workspace 两类按钮同路径修复，避免在每个调用点重复。 |
| 状态改为实心 / 环形加内点 / 空心 | 不增加图例和文案，在 64pt 轨道内为三种状态提供非颜色线索。 |
| footer 共享样式提供 32×32 最小命中区和 0.97 按压缩放 | 全部调用方都是侧边栏图标按钮，修共享样式比逐个包装更小。 |
| 恢复系统滚动指示 | macOS 默认为覆盖式指示，无需自研位置组件。 |

## 风险与边界

- 滚动和视觉层级没有现成单元测试 API，以 Swift 编译、现有 Compact 投影测试和真实 UI 边界说明覆盖。
- 不删除 Compact 底部动作，不调整图标颜色算法；这些都需要额外用户证据。
- 初始任务不含发布；用户后续明确追加 Beta 发布要求，因此扩展范围并发布 beta.14。

## 发布真相

- PR `#115` squash merge 为 `5a6258c`，main push CI `30170340052` 成功。
- 新 Beta 为 `desktop-v0.0.8-beta.14`，tag 指向 `5a6258c`。
- release run `30170521910` 的 verify / package / publish 全部成功，两道 `desktop-release` environment 已自动批准。
- GitHub Release 为 Pre-release，包含 DMG、ZIP、从 `0.0.7` 和 `0.0.8-beta.13` 升级的两个 delta。
- appcast 顶部为 `0.0.8-beta.14`，数字 build `44`，带 `beta` channel、EdDSA 签名和两个 delta。
- CI 写回 appcast 的 main commit 为 `b09b9ed`，本地 main 已 fast-forward 同步。

## 参考指针

- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `.planning/sidebar-compact-mode-2026-07-22_18-05-04/`
