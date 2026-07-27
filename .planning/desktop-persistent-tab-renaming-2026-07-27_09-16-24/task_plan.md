# 任务计划：desktop-persistent-tab-renaming

- 任务 ID：`desktop-persistent-tab-renaming-2026-07-27_09-16-24`
- 创建时间：`2026-07-27_09-16-24`

## 目标

让用户从顶部标签右键菜单重命名或清除名称；自定义标题跨刷新、重启、窗格移动和多设备布局同步保持，并始终优先于终端 OSC 标题。

## 范围

- 在 `WorkspaceTerminalLayout` 建立按 session 保存的自定义标题真源。
- 开放 Bonsplit 的 rename / clearName 动作并实现原生 macOS 输入对话框。
- 统一顶部标签、侧边栏、命令面板和检查器的标题解析。
- 增加旧布局兼容、清理、持久化和真实菜单动作测试。

## 非目标

- 不把自定义标题写入 daemon Session 或协议 schema。
- 不增加标签快捷键、命令面板重命名入口或服务端独立 metadata RPC。
- 不修改终端 OSC 标题采集行为。

## 关键约束

- 标题优先级为 custom title > OSC title > cwd 尾段 >「终端」。
- 输入 trim 后为空等同清除；相同标题不重复写布局。
- 旧布局缺少新字段时必须无损解码。
- 仅标题变化不能重建 BonsplitController 或终端 surface。
- 自定义标题按 server/workspace/session 隔离；session 删除或 prune 时清理。
- 旧客户端仍可能在写回布局时丢弃新字段，此混合版本边界必须明确记录。

## 修改路径

- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Resources/*/Localizable.strings`
- `apps/desktop-macos/scripts/package-app.sh`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 针对性 Swift Testing：布局兼容、标题优先级、菜单动作、metadata-only 更新。
- Desktop 全量 Swift 测试、Bonsplit 测试、`pnpm check`、`pnpm build`。
- 打包产物验证三种语言资源与稳定签名。
- 热替换 UI/runtime，保留当前 daemon 和终端会话。

## 验收标准

- 右键“重命名标签”可输入名称，确认后顶部标签立即更新。
- 自定义名称不会被 OSC/cwd 刷新覆盖；清除后立即显示最新动态标题。
- 重排、跨窗格移动、重启和服务端 layoutRev 刷新后仍保留名称。
- 关闭或移除 session 后不残留名称。
- 只有名称变化时终端 surface 不重建。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 标题随 WorkspaceTerminalLayout 持久化 | 现有布局已同时覆盖本机快照和 `workspace.setLayout` 多端同步 |
| 不写 daemon Session.title | 该字段属于终端 OSC 动态标题，混写会产生双真源 |
| metadata-only 更新不 restore | restore 会重建 Bonsplit 与终端 surface，属于可见抖动 |
| 使用同一 mutation 处理 rename / clear | 避免菜单两个入口产生不同 trim、清理和持久化语义 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
