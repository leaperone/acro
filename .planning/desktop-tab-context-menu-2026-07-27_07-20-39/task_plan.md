# 任务计划：desktop-tab-context-menu

- 任务 ID：`desktop-tab-context-menu-2026-07-27_07-20-39`
- 创建时间：`2026-07-27_07-20-39`

## 目标

为 Acro 顶部终端标签提供可用的右键菜单，只显示能够完整执行的动作，并保持关闭确认、Runtime 会话终止和布局持久化语义正确。

## 范围

- 为 Bonsplit 增加宿主可见动作白名单，默认行为保持不变。
- Acro 开放关闭左侧、关闭右侧、关闭其他、移到相邻窗格、缩放窗格和全宽标签。
- 批量关闭只确认一次，成功终止对应 Runtime 会话后再移除标签。
- 为 Acro 显示的 Bonsplit 菜单项补充简体中文。

## 非目标

- 不实现标签重命名、固定、未读、浏览器、移动到其他工作区或复制标识符。
- 不增加新的快捷键或设置项。

## 关键约束

- 菜单不能显示无效动作或空子菜单、连续分隔线。
- 批量关闭必须复用单标签的 `session.remove` / `session.kill` 兼容路径，不能只改 UI 布局。
- 右键目标不必先成为当前标签；动作必须针对被点击标签及其窗格。

## 修改路径

- `apps/desktop-macos/Vendor/bonsplit/` 的配置、菜单构建、资源与测试。
- `TerminalPaneController.swift`、`WorkbenchModel.swift`、`WorkbenchView.swift` 与宿主测试。

## 验证方式

- 先增加红色测试，锁定白名单菜单、批量终止和右键动作路由。
- 实现后运行 Bonsplit 测试、Desktop 全量、`pnpm check`、`pnpm build` 和 release script tests。

## 验收标准

- 右键菜单只包含 Acro 支持的动作，中文显示且无空分组。
- 关闭左/右/其他只弹一次确认，并终止全部目标会话。
- 移动、缩放和全宽动作更新正确的 Bonsplit 状态与持久化布局。
- 原有拖拽、单标签关闭和 cmux 默认全菜单不回归。

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
| 在 Bonsplit 配置增加动作白名单 | 菜单构建器当前固定输出全部产品动作；宿主过滤是消除假菜单的共享根因。 |
| Acro 首批只开放七个已闭环动作 | 其它动作缺少产品状态或 Runtime 契约，显示即为无效 UI。 |
| 不开放 `newTerminalToRight` | 异步创建链尚无右键锚点重排契约，直接开放会插错位置。 |
| 批量关闭复用会话终止 helper | 保持 `session.remove` 到 `session.kill` 的兼容语义，避免 UI 与 Runtime 漂移。 |
| 批量终止顺序执行并只刷新一次 | 每个成功项立即关闭对应标签，失败项保留；一次 refresh 收敛服务端快照。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Swift 无法在合理时间内推断扩展后的菜单 View 表达式 | 1 | 提取 `contextMenuSnapshot` 计算属性，保持行为不变并恢复编译。 |
| `TabContextMenuSnapshot` 默认成员初始化器不接收 allowlist | 1 | 增加显式初始化器并为 allowlist 保留 `nil` 默认值。 |
| 新增简体中文资源被既有 `Resources` ignore 规则隐藏 | 1 | 保留现有 ignore 规则，提交时显式跟踪该资源，并从 Git 索引复核。 |
