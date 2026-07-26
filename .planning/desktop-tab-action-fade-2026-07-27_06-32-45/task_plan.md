# 任务计划：desktop-tab-action-fade

- 任务 ID：`desktop-tab-action-fade-2026-07-27_06-32-45`
- 创建时间：`2026-07-27_06-32-45`

## 目标

让 Acro minimal 标签栏右侧动作按钮使用 cmux 当前生产渐隐参数，避免 hover 时尾部标签被硬盖、文字突然截断和分隔线断裂。

## 范围

- 只修改 `TerminalPaneController` 的 Bonsplit appearance。
- 增加 Acro 宿主配置回归，锁定生产参数。

## 非目标

- 不修改 vendored Bonsplit。
- 不接入终端主题颜色、右键菜单或 divider 命中区。
- 不增加调试设置或可调参数。

## 关键约束

- 复用 cmux 已投产常量，不复制其 Debug 调参面板。
- 保持 minimal、拖拽、按钮行为和禁用动画语义不变。

## 修改路径

- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 先增加失败测试，证明 Acro 当前未设置显式 effect。
- 实现后运行针对性测试、全量 Desktop、`pnpm check`、`pnpm build` 和 CI。

## 验收标准

- Acro controller 显式持有与 cmux 生产一致的 backdrop effect。
- 动作区遮罩开启，content fade、separator fade、solid surface 和 occlusion 参数一致。
- 标签重排与 minimal 启动回归继续通过。

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
| 只接生产 effect，不复制调试系统 | Acro 需要稳定视觉结果，不需要 cmux 的内部调参入口。 |
| 不顺带修改 dividerHitExpansion | 与本轮 hover 动作区根因无关。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无 |
