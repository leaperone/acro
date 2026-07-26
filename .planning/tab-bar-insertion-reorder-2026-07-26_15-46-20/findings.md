# 调研与结论：tab-bar-insertion-reorder

- 任务 ID：`tab-bar-insertion-reorder-2026-07-26_15-46-20`
- 创建时间：`2026-07-26_15-46-20`

## 需求事实

- 用户确认窗格间移动已经可用，但顶部同一标签栏内“标签和标签之间”的拖拽排序不可用。
- Acro 当前已有排序状态模型和持久化，不是从零实现功能。

## 真实调用链

- `PaneTabItem.onDrag` 创建 `TabDragPayload`，当前标签本体和外层整条 `PaneTabBar` 同时注册 `.onDrop`。
- 外层 drop 把任何命中解释成 `pane.sessionIds.count`，子标签 drop 才会传目标 `index`。
- `WorkbenchModel.moveTab` 校验 payload 后调用 `WorkspaceTerminalLayout.moveTab`；该方法已经处理同窗格向后移动的下标修正。
- `workspaceLayouts` 变化继续走现有本地快照与 `workspace.setLayout` 同步链路。

## 调研结论

- 状态层测试已经覆盖同栏前移、后移、取消和末尾排序；缺口在 UI 落点解析。
- cmux 顶部标签排序由私有 Bonsplit 内建，Acro 当前依赖的 Bonsplit 只是快照类型 shim，不能通过一个配置开关获得该 UI 能力。
- Orca 将目标标签按中点分成 before / after，并只显示插入线；这正好补足 Acro 的落点语义，不需要移植其 dnd-kit、pointer sensor 或跨 WebView 兼容层。

## 技术决策

| 决策 | 证据 |
|---|---|
| 一个标签 drop target 同时解析左半区和右半区 | Orca `tab-insertion.ts` 使用目标矩形中点；可表达所有 `0...count` 插入位置 |
| 删除父级重叠 drop，末尾由最后一个标签右半区表达 | 当前父级和子级目标范围重叠；额外 viewport 末尾区在溢出滚动时还会覆盖最右可见标签 |
| 保留现有 `moveTab` | `WorkbenchLayoutStateTests.testSamePaneReorder` 已证明下标修正正确 |

## 风险与边界

- SwiftUI 拖拽没有现成单元测试入口，需要把“左右半区到插入下标”的纯逻辑留成可执行测试 seam。
- 本机运行版本可能落后于 main；实现后必须热替换并做真实 UI 验证。
- GitHub DNS 当前不可用，cmux / Orca 未能 pull 到远端最新提交。
- 本机 Computer Use 和 shell Accessibility / Screen Recording 权限不可用；最终构建已启动，但未能自动执行真实鼠标拖拽。

## 参考指针

- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`
- `.tmp/cmux/Sources/Workspace.swift`
- `.tmp/orca/src/renderer/src/components/tab-group/tab-insertion.ts`
