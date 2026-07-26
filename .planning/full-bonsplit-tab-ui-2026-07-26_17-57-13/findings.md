# 调研与结论：full-bonsplit-tab-ui

- 任务 ID：`full-bonsplit-tab-ui-2026-07-26_17-57-13`
- 创建时间：`2026-07-26_17-57-13`

## 需求事实

- 用户指出 Acro 顶部标签栏 UIUX 明显低于 cmux，并明确授权完整 Bonsplit 架构替换。
- beta.17 的左右半区 drop 只修复“能排序”，没有覆盖 cmux 的完整设计。

## 真实调用链

- Acro 当前：`TerminalPanesView` 自行渲染 split tree、`PaneTabBar`、`PaneTabItem`、SwiftUI `onDrag/onDrop` 和 `PaneDropTargetLayer`；`WorkbenchModel` 修改 `WorkspaceTerminalLayout` 后持久化。
- cmux 当前：`Workspace` 配置 `BonsplitController`，`BonsplitView` 渲染；Bonsplit 内部统一处理 AppKit 手动重排、系统 drag/drop、pane split、scroll geometry、窗口拖动隔离和 lifecycle；delegate 将最终行为通知宿主。
- 目标：Bonsplit controller 直接处理运行期交互，Acro bridge 将 delegate/controller 快照转换回现有 `WorkspaceTerminalLayout`。

## 调研结论

- cmux 已更新到 `f79e3d86`，Bonsplit gitlink 为 `48643102`。
- Bonsplit 是公开 MIT 包、macOS 14、无第三方依赖；可直接替换 Acro 的 shim。
- cmux 的手动重排使用真实 AppKit frame、4pt 阈值、tab midpoint、mouse-up commit、相邻 no-op 抑制；不做 live reflow 或 spring。
- Bonsplit 还提供 drag preview、自动 reveal、scroll fade、稳定 close slot、完整尾部空白落点、窗口拖动命中隔离、跨 pane/split 和统一取消清理。
- 旧 dirty worktree 已证明完整接入方向可编译，但固定旧 commit、没有测试日志、缺最新尾部落点和当前文件拖放/侧栏/生命周期修复。

## 技术决策

| 决策 | 证据 |
|---|---|
| 删除自研 pane/tab UI，不继续打补丁 | 当前缺口横跨交互、几何、滚动、生命周期和无障碍，不是视觉常量问题 |
| 保留现有持久化 schema | Runtime 与多端同步契约已存在，产品不需要迁移服务端数据 |
| 新增一个 Acro 侧 controller bridge | Bonsplit 没有公开任意树 import API，需要按快照顺序重建并由 delegate 回写 |
| 使用 `.keepAllAlive` | 保持 Acro 后台 TUI 持续渲染与零延迟切换语义 |

## 风险与边界

- 全量 Bonsplit 约 36 个 Swift 文件、13k 行；vendor diff 大，但来源单一且无需维护自研交互。
- 旧 bridge 不能直接复用：`leftSidebarVisible` 已被三态 sidebar 替代，缺 `onFileDrop`，并可能覆盖当前 reconcile/点击保护。
- 真实 UI 自动化权限此前不可用；必须至少完成启动验证并给出人工验收边界。
- 当前主线已确认所有共享动作必须优先路由到 workspace 对应的 `TerminalPaneController`；侧边栏、命令面板、快捷键和鼠标不能再直接修改运行期快照。
- Bonsplit 的 `onFileDrop` 会覆盖终端内容区拖放命中，因此桥接必须按目标 pane 的选中 tab 路由到既有 `AcroTerminalNSView.handleDroppedURLs`，并拒绝被其他设备占用的终端。
- 完整 Bonsplit 自带 202 项测试，已覆盖尾部整栏 drop、4pt 手动拖拽、取消和陈旧 generation、滚动几何、窗口拖动命中、文件落点与 resize anchor；Acro 不重复实现这些内部算法。

## 参考指针

- `.tmp/cmux` commit `f79e3d8677127484bf2cb1153c62f28ccd9937c6`
- `.tmp/cmux/vendor/bonsplit` commit `48643102d6b68400069429bd43c15d7bda2b00a1`
- Bonsplit `TabBarView.swift`、`TabItemView.swift`、`TabBarItemGeometryRegistry.swift`、`PaneContainerView.swift`、`TabDragPreview.swift`
- 旧参考 worktree `.claude/worktrees/fix-desktop-use-full-bonsplit`（只读保留）
