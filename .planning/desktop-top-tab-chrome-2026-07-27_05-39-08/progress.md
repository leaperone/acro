# 执行进度：desktop-top-tab-chrome

- 任务 ID：`desktop-top-tab-chrome-2026-07-27_05-39-08`
- 创建时间：`2026-07-27_05-39-08`
- 当前状态：`in_progress`

## 已完成

- 更新并确认 cmux reference 已在 `aac23518`。
- 对比 Acro 与 cmux vendored Bonsplit，相关文件完全一致。
- 追踪真实重排、布局持久化、标题栏 safe area 和 presentation mode 调用链。
- 新增启动模式回归：当前 Acro 初始化后 key 仍为 nil，按预期失败。
- 新增真实窗口顶边断言；当前 main 已贴顶。
- 将真实重排测试固定到 minimal 模式，仍可重排并持久化。

## 进行中

- 提交失败测试并取得 CI 红色证据。

## 修改文件

- `.planning/desktop-top-tab-chrome-2026-07-27_05-39-08/*`
- 预计修改 `AcroApp.swift` 和桌面交互测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| cmux reference pull | 已是最新 `aac23518` | 已通过 |
| Bonsplit vendor 比较 | TabBarView、TabItemView、TabBarMetrics 逐字一致 | 已确认 |
| 当前中心点拖拽测试 | 真实 `NSWindow + NSEvent` 可重排并持久化 | 已有证据 |
| Computer Use | Orca runtime 未运行 | 未做真实 UI 验证 |
| 启动模式回归 | 期望 minimal，实际 nil | 红色测试 |
| 真实窗口顶边 + minimal 拖拽 | 通过 | 已通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Orca Computer Use `runtime_unavailable` | 1 | 按仓库规则停止重试，改用可重复窗口测试 |
| GhosttyKit `ghostty.h` 缺失 | 1 | 运行项目 setup 脚本补齐 worktree 构建资产 |
| 顶部 2pt 合成拖拽测试挂起 | 1 | 终止测试；分离顶边几何与中心拖拽，避免把 AppKit 合成事件限制当真实行为 |
