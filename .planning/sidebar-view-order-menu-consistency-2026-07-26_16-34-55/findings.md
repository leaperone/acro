# 调研与结论：sidebar-view-order-menu-consistency

- 任务 ID：`sidebar-view-order-menu-consistency-2026-07-26_16-34-55`
- 创建时间：`2026-07-26_16-34-55`

## 需求事实

- 用户明确要求 Full/Compact 只改变 UI 呈现，实体顺序、选择、快捷键和交互语义保持一致。
- 用户追加要求重新设计并统一两种模式下各处右键菜单。

## 真实调用链

- 服务器：`ClientConfig.servers` → `RuntimeHub.entries` → `SidebarServerProjection.entries` → Full/Compact。
- Workspace：Runtime snapshot → `workspaceGroups.workspaceIds` / 未分组 `workspaces` → Full/Compact。
- `⌘1-9`：`ShortcutSettings.workspaceDigit` → `WorkbenchModel.selectWorkspace(number:)` → `orderedWorkspaces`。
- Workspace 菜单动作最终进入 `WorkbenchModel`；服务器编辑/移除进入 `ServerDirectory` 或现有 sheet/confirmation 状态。

## 调研结论

- 当前服务器和 Workspace 数据顺序已经共享；上一轮“各自排序”的交付文案错误。
- `⌘1-9` 与两种视图当前均使用当前服务器的同一 Workspace 顺序，切换 presentation 不改选择。
- 真实缺口一：服务器拖拽排序只在 Compact 暴露。
- 真实缺口二：Full/Compact 的服务器和 Workspace 右键菜单分别手写，能力、顺序和禁用状态明显漂移。
- 分组与 Session 只在 Full 中有可见实体，不应在 Compact 制造无锚点菜单。
- 原菜单普遍依赖 `activate(serverId) → 从 runtime 推断 RPC 目标`；陈旧菜单在服务器被移除后可能回落到另一台服务器。现已改成显式目标并失败关闭。
- Full 原“远程设置…”没有携带目标服务器，实际会打开默认设置状态；共享菜单改成明确的全局“设置…”，Full/Compact 行为一致。

## 技术决策

| 决策 | 证据 |
|---|---|
| 同一实体的菜单由共享组件生成 | Full Workspace 有移动/重命名/删除，Compact 只有跳转；服务器菜单也缺少新建分组、编辑、移除和设置。 |
| Compact 直接执行实体动作 | 这些动作已有 connection-scoped 路由和确认流程，不需要切到 Full 才能完成。 |
| 不新增动画 | 右键菜单和快捷键是高频原生交互，系统反馈已经足够。 |

## 风险与边界

- Compact 新增删除入口必须复用现有确认状态，不能直接删除。
- 菜单闭包必须捕获目标 entry/connection，避免操作非当前服务器时路由错误。
- SwiftUI `Equatable` 行可能保留旧闭包；菜单输入必须来自当前 snapshot 或 live connection。
- Acro 当前没有多语言 catalog；本轮复用已有中文菜单文案，不新增本地化键。
- 菜单规范调整了既有中文文案的省略号，并新增目标已移除类错误；Acro 当前无本地化 catalog，无法执行多语言 catalog 对齐。

## 参考指针

- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `.planning/compact-sidebar-reorder-2026-07-26_15-27-39/`
