# 执行进度：desktop-agent-attention-badges

- 任务 ID：`desktop-agent-attention-badges-2026-07-27_08-07-11`
- 创建时间：`2026-07-27_08-07-11`
- 当前状态：`in_progress`

## 已完成

- 已复核协议、Runtime 事件、SwiftUI 快照、PaneController 与 Bonsplit badge 调用链。
- 已确认本增量不需要改协议或 Vendor 代码。

## 进行中

- 添加未读状态的行为回归测试。

## 修改文件

- `.planning/desktop-agent-attention-badges-2026-07-27_08-07-11/*`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 项目基线 | worktree 指引、planning 和 ignore 约束有效 | 通过 |
| 首次针对性 Swift 测试 | worktree 缺少忽略的 Ghostty header，未进入测试执行 | 环境阻断 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 1 | 无 |
| `GhosttyKit/ghostty.h` 不存在 | 1 | 将复用主 checkout 现有同版本产物后重跑 |
