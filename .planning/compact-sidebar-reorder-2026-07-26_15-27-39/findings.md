# 调研与结论：compact-sidebar-reorder

- 任务 ID：`compact-sidebar-reorder-2026-07-26_15-27-39`
- 创建时间：`2026-07-26_15-27-39`

## 需求事实

- 用户要求 Compact 内可拖拽排序 Workspace 和服务器。
- 用户发现 Compact 默认顺序与 Full 不同，本机未置顶。
- 用户补充要求按住 Command 时显示 Full 已有的 `⌘+数字` 提示。

## 真实调用链

- 服务器：`~/.acro/client.json` → `ClientConfig.servers` → `RuntimeHub.entries` → Sidebar 渲染。
- Full 当前视图层先渲染本机、再渲染远程；Compact 直接遍历 `hub.entries`，因此默认顺序漂移。
- Workspace：Full 的 `.onDrag` → `WorkspaceDragPayload` → 上下半区 planner/DropDelegate → `WorkbenchModel.requestReorderWorkspace` → `workspace.reorder` RPC → Runtime 持久化。
- 快捷键提示：`WorkbenchModel.cmdHeld` → `workspaceShortcutDigit` → Full `WorkspaceRow.shortcutHint`；Compact 尚未投影该字段。

## 调研结论

- Runtime 已支持组内、跨组和未分组 Workspace 重排，不需要改协议或服务端。
- `RuntimeHub.reload()`复用既有连接，纯服务器排序不会断开 Runtime 或终端。
- `pairLocal`凭据变化时会删除本机后追加到末尾，是配置顺序漂移的来源之一。
- Full 的 Workspace drop 会先 activate 源服务器，导致排序时切换当前终端，应改为显式 connection 路由。
- Compact 监听有序 workspace ID 数组，任何重排都会触发 `scrollToSelection`，应只监听成员增删。
- Full 的 Equatable WorkspaceRow 动作闭包可能捕获旧 `group.workspaceIds`；drop 时必须按目标 Workspace 从 connection 重新读取当前分组和顺序。
- Workspace 重排只会让发起端主动 refresh，其他在线客户端不会立即收到排序事件；这是现有协议边界，本轮不扩张为多端实时同步。

## 技术决策

| 决策 | 证据 |
|---|---|
| 抽取共享服务器投影为本机优先、远程保序 | Full 当前已明确采用该语义，Compact 缺少同一投影。 |
| 服务器排序只重排远程子序列 | 本机是本地 Runtime 入口，不是普通配对服务器；用户明确要求默认置顶。 |
| 原生 `.onDrag/.onDrop` + 2pt 插入线 | 与 Full 现有交互一致，点击和拖拽阈值由系统处理。 |

## 风险与边界

- 两类拖拽都声明 `UTType.text`，必须用内存 payload 严格区分服务器和 Workspace。
- provider 可能延迟释放，payload token 必须防止旧拖拽清掉新状态。
- 空分组在 Compact 不可见，因此不能作为 Compact drop 目标。
- 自动截图和 VoiceOver 仍受 Screen Recording / Accessibility 权限限制。

## 参考指针

- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/ServerDirectory.swift`
- `packages/protocol/src/rpc.ts`
- `apps/runtime/src/workspaces.ts`
- 只读审查：`impact_sidebar_code`、`impact_sidebar_ui`
