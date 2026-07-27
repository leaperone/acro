# 任务计划：native-window-drag

- 任务 ID：`native-window-drag-2026-07-27_14-42-42`
- 创建时间：`2026-07-27_14-42-42`

## 目标

让 Acro 侧栏标题栏空白区使用 macOS 原生窗口拖动事务，恢复系统吸附、跨屏约束、放大窗口拖动恢复和中断处理，同时继续隔离标签与内容区的隐式拖窗。

## 范围

- 只修改三个侧栏空白拖动入口共用的 `WindowDragNSView`。
- 添加真实 `NSWindow.performDrag(with:)` 行为回归测试。
- 保留 Beta.27 顶部标签点击、排序、分屏按钮和 safe-area 修复。

## 非目标

- 不修改 Bonsplit 标签栏拖动实现。
- 不重新设计标题栏或侧栏视觉。
- 不在本增量改变标题栏双击偏好解析；继续保持当前双击 zoom 行为。

## 关键约束

- 窗口全局继续保持 `isMovable=false` 与 `isMovableByWindowBackground=false`。
- 仅在显式拖动调用期间临时恢复 `isMovable`，结束后无条件还原。
- 测试先独立提交失败用例，再提交产品修复。
- 不重启 terminal daemon。

## 修改路径

- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- `swift test --package-path apps/desktop-macos --filter TerminalPanesInteractionTests`
- `swift test --package-path apps/desktop-macos`
- `swift build --package-path apps/desktop-macos -c release`
- `pnpm check`、`pnpm build`、CI package smoke。

## 验收标准

- 单击三个侧栏标题栏空白入口会调用一次原生 `performDrag`。
- `performDrag` 调用期间窗口可移动，返回后恢复不可移动。
- 标签点击、标签拖拽和右侧分屏按钮不会触发侧栏窗口拖动。
- 双击仍只执行 zoom，不进入窗口拖动。

## 未确认事项

无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 复用 AppKit `performDrag` | macOS 自己管理吸附、跨屏、放大窗口恢复和拖动中断；手工坐标更新无法完整复制 |
| 不抽取新 helper | `WindowDragNSView` 是唯一共享入口，局部保存/恢复 `isMovable` 已足够 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| fresh worktree 缺少 `GhosttyKit/ghostty.h` | 1 | 运行仓库现有 `setup-ghostty.sh` 补齐资产后，目标测试进入真实断言 |
