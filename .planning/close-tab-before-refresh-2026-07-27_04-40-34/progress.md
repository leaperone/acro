# 执行进度：close-tab-before-refresh

- 任务 ID：`close-tab-before-refresh-2026-07-27_04-40-34`
- 创建时间：`2026-07-27_04-40-34`
- 当前状态：`in_progress`

## 已完成

- 核对全部关闭入口、共享 mutation 路径、Bonsplit controller 和焦点所有权调用链。
- 确认当前实现先逐出 surface、后等待 refresh、最后关闭标签。
- 增加可控 RPC/refresh 的真实 `terminateSession` 行为测试。
- 修复前测试按预期失败 6 项，直接覆盖 refresh 等待窗口中的标签、选择、layout 和焦点状态。

## 进行中

- 提交修复前失败测试并让 PR CI 留下红色证据。

## 修改文件

- `.planning/close-tab-before-refresh-2026-07-27_04-40-34/*`
- 预计修改 `RuntimeConnection.swift`、`WorkbenchModel.swift`、`TerminalPanesInteractionTests.swift`。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码调用链 | RPC 后先 evict，再 refresh，最后 close | 已确认缺陷 |
| 修复前定向测试 | 1 test，6 个期望失败 | 按预期失败 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 0 | 无 |
