# 任务计划：compact-sidebar-reorder

- 任务 ID：`compact-sidebar-reorder-2026-07-26_15-27-39`
- 创建时间：`2026-07-26_15-27-39`

## 目标

让 Compact 侧边栏支持服务器和 Workspace 的原生拖拽重排，并与 Full 侧边栏共享默认顺序和持久化顺序；按住 Command 时显示 `⌘+数字` Workspace 切换提示。

## 范围

- 本机服务器固定首位，远程服务器可在 Compact 内拖拽重排并写入客户端配置。
- Workspace 可在同一服务器内组内、跨组和未分组区域拖拽重排，复用现有 Runtime RPC。
- Full 与 Compact 共用本机优先、远程保序的服务器投影。
- Compact 显示与 Full 相同的 `⌘1-9` 提示。
- 修复重排导致服务器选择切换和 Compact 列表跳回选中项的问题。

## 非目标

- 不允许 Workspace 跨服务器迁移。
- 不在 Compact 展示或管理空分组，结构管理继续保留在 Full。
- 不新增协议、依赖、自定义手势或独立排序字段。
- 不发布新 Beta；本轮只完成代码、PR、合并和本机 dev 验证。

## 关键约束

- 排序真相源保持现有 `ClientConfig.servers`、`workspaceGroups.workspaceIds` 和 Runtime `workspaces`。
- 拖拽只挂到服务器 Header 和 Workspace Button，不能吞掉点击、菜单或内部拖拽。
- 落点即时显示 2pt Accent 插入线，不增加弹跳动画；减少动态效果时行为不退化。
- 重排不得改变当前服务器、Workspace、Session 或 `ClientConfig.active`。
- 服务器配置损坏时失败关闭，不能用空配置覆盖。

## 修改路径

- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/ServerDirectory.swift`
- 相关 desktop tests 与本任务 planning。

## 验证方式

- Compact/Sidebar/ClientConfig 针对性 Swift 测试。
- 完整 `swift test`、`swift build`、`pnpm check`、`pnpm build`、`git diff --check`。
- 打包并热替换本机 dev UI/runtime，保留 daemon，验证实际进程和版本。
- 系统权限仍不可用时，不重复尝试截图或 VoiceOver 自动化。

## 验收标准

- [x] Compact 默认本机在最上，远程顺序与 Full 一致。
- [x] 拖动远程服务器 Header 可改变顺序，重启或切换模式后保持。
- [x] 拖动 Workspace 可在同服务器内调整顺序和分组归属，不切换当前服务器。
- [x] 按住 Command 时，当前服务器的 Workspace 显示与 `⌘1-9` 实际切换一致的提示。
- [x] 重排非选中 Workspace 后，Compact 不自动跳回选中项。

## 未确认事项

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 本机固定首位，只排序远程服务器 | 延续 Full 的既有产品语义，并直接修复两种模式默认顺序不一致。 |
| 复用 Full 的 Workspace payload、planner、provider 和 DropDelegate | 避免两套拖拽语义与边界处理继续漂移。 |
| Workspace reorder 显式接收源 connection | 排序是后台结构操作，不应为了 RPC 路由切换用户当前服务器。 |
| 服务器顺序直接写回 `ClientConfig.servers` | 现有数组已经保序，无需新增 sortIndex 或协议。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 自定义 UTType 测试缺少 `UniformTypeIdentifiers` import | 1 | 补充显式 import 后针对性与全量测试通过。 |
| 热替换首次 `open` 返回 LaunchServices `-609` | 1 | 使用 `open -n` 创建新 dev UI；daemon 未重启。 |
