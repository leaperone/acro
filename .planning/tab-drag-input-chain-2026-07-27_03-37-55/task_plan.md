# 任务计划：tab-drag-input-chain

- 任务 ID：`tab-drag-input-chain-2026-07-27_03-37-55`
- 创建时间：`2026-07-27_03-37-55`

## 目标

用真实 AppKit 鼠标事件证明并修复 Acro 顶部标签从一个标签拖到另一个标签时的排序链，达到 cmux 同源 Bonsplit 的实际交互效果。

## 范围

- 挂载 Acro 使用的 Bonsplit 配置和真实标签视图。
- 发送 `leftMouseDown → leftMouseDragged → leftMouseUp`，验证标签顺序和持久化布局。
- 若事件链失败，只修复断点所在的宿主或 Bonsplit 共享根因。

## 非目标

- 不重写 Bonsplit 拖拽算法。
- 不修改窗格分屏、侧栏排序或标签视觉主题。
- 不用控制器 `reorderTab` 调用代替鼠标拖拽验收。

## 关键约束

- 保持标签 4pt 启动阈值、插入位置、跨窗格能力和窗口拖动隔离与 cmux 一致。
- 不在终端输入热路径增加日志或布局工作。

## 修改路径

- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- 仅在测试证明真实断点时修改对应产品或 vendored Bonsplit 文件。

## 验证方式

- 针对性 Desktop 测试。
- Bonsplit 全量测试（若修改 vendor）。
- Acro Desktop 全量测试、`pnpm check`、`pnpm build`。
- Computer Use 只尝试一次；不可用时记录真实桌面验收边界。

## 验收标准

- 真实 NSEvent 链能将第一个标签拖到目标标签之后。
- `didReorderTabsInPane` 触发，`WorkspaceTerminalLayout` 持久化新顺序。
- 顶部 safe-area 修复不造成坐标错位。

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
| 先补真实输入链测试 | 现有测试只调用控制器 API，不能证明用户拖拽可用 |
| 复用 vendored Bonsplit | Acro 与 cmux 均使用 Bonsplit `48643102`，不存在版本缺失 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Orca Computer Use runtime 未启动 | 1 | 按项目规则停止重试，使用真实 AppKit 事件与窗口验证 |
