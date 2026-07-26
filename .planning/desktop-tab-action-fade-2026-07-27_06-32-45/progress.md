# 执行进度：desktop-tab-action-fade

- 任务 ID：`desktop-tab-action-fade-2026-07-27_06-32-45`
- 创建时间：`2026-07-27_06-32-45`
- 当前状态：`in_progress`

## 已完成

- 对照 PR #131 后的 Acro 与最新 cmux 宿主配置。
- 确认标签高度、minimal、拖拽和 overflow 已一致。
- 确认下一差距位于 `splitButtonBackdropEffect`。
- 新增宿主配置回归；当前 effect 为 nil，按预期失败。

## 进行中

- 提交红色测试，再接入 cmux 生产 effect。

## 修改文件

- 预计修改 `TerminalPaneController.swift`、`TerminalPanesInteractionTests.swift`。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码对照 | Acro 使用默认 effect，cmux 使用显式生产值 | 已确认 |
| `terminalTabsUseCmuxActionLaneFade` | effect 实际为 nil | 红色测试 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 1 | 无 |
