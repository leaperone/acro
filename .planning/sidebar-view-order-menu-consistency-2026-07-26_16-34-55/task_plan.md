# 任务计划：sidebar-view-order-menu-consistency

- 任务 ID：`sidebar-view-order-menu-consistency-2026-07-26_16-34-55`
- 创建时间：`2026-07-26_16-34-55`

## 目标

让 Full 与 Compact 成为同一侧边栏实体模型的两种呈现：共享服务器和 Workspace 顺序、选择状态、快捷键映射、拖拽写入以及同一实体的右键菜单能力。

## 范围

- Full 远程服务器标题支持与 Compact 相同的拖拽排序，继续复用 `ClientConfig.servers`。
- 服务器和 Workspace 的核心右键菜单由共享组件生成，动作顺序、禁用条件和路由一致。
- Compact 直接提供 Workspace 移动分组、重命名、删除，以及服务器新建分组、编辑、移除、设置入口。
- Full/Compact 视图专属动作只放在共享核心菜单末尾。
- 补充模式切换、服务器切换、重排后 `⌘1-9` 映射保持一致的契约测试。

## 非目标

- 不新增独立排序字段、协议或 Runtime RPC。
- 不把 `⌘1-9` 改为跨服务器全局编号；它继续作用于当前服务器。
- Compact 不显示分组行或 Session 行，因此不创建不可见实体的右键菜单。
- 不改变 Workspace 跨组拖拽能力、折叠行为或侧边栏视觉密度。

## 关键约束

- 服务器顺序唯一真相源仍是 `ClientConfig.servers`，本机固定首位。
- Workspace 顺序唯一真相源仍是 Runtime 的 `workspaceGroups.workspaceIds` 与未分组 `workspaces` 相对顺序。
- 菜单动作必须显式路由到目标服务器的 connection，不能为了执行后台动作切换当前选择。
- 复用现有文案，不引入新的本地化表面。
- 危险动作保持 destructive role，并继续使用现有确认流程。

## 修改路径

- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`（仅在共享动作路由确有需要时）
- `apps/desktop-macos/Tests/` 下相关排序、快捷键和侧边栏测试

## 验证方式

- 针对性 Swift 测试锁定共享菜单输入、服务器排序和 Workspace 数字映射。
- 完整 `swift test`、`swift build`、`pnpm check`、`pnpm build`、`git diff --check`。
- 打包并热替换本机 dev UI/runtime，保留 daemon；使用 Computer Use 检查 Full/Compact 右键菜单与拖拽入口。

## 验收标准

- [x] Full 与 Compact 显示同一服务器和 Workspace 顺序。
- [x] Full 与 Compact 都能重排远程服务器，且切换视图后结果不变。
- [x] 同一服务器实体的核心菜单项、顺序和禁用状态一致。
- [x] 同一 Workspace 实体的核心菜单项、顺序和动作结果一致。
- [x] 切换 Full/Compact 不改变当前实体或 `⌘1-9` 映射。
- [x] 重排 Workspace 后提示数字与实际快捷键选择同步。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 共享菜单 View，而不是复制两份 `contextMenu` | 用户要求同一实体能力长期一致；单一生成点最小且可防止再次漂移。 |
| 保留视图专属菜单项 | “在完整侧边栏中显示”属于导航，不是实体能力，放在核心动作之后即可。 |
| Full 服务器标题复用现有拖拽 payload、planner 和持久化函数 | 不引入第二套排序语义。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| HTTPS fetch 临时 DNS 失败 | 1 | 使用一次性 SSH 443 URL 映射后创建 worktree，不修改仓库 remote。 |
