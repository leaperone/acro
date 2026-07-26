# 执行进度：desktop-tab-theme-chrome

- 任务 ID：`desktop-tab-theme-chrome-2026-07-27_06-56-48`
- 创建时间：`2026-07-27_06-56-48`
- 当前状态：`in_progress`

## 已完成

- 对照最新 Acro、cmux 和 vendored Bonsplit 的主题调用链。
- 确认根因是 finalized Ghostty 配置没有传播到 Bonsplit controller。
- 确认全部缓存 controller 的统一更新入口位于 `WorkbenchModel`。
- 增加 Ghostty finalized config 与全部缓存 controller 的红色回归。

## 进行中

- 实现 Ghostty 外观快照和 Bonsplit 分发链。

## 修改文件

- 预计修改 Ghostty、WorkbenchModel、TerminalPaneController、WorkbenchView、SettingsView 和对应测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码对照 | Ghostty reload 与 Bonsplit appearance 当前断链 | 已确认 |
| 针对性红测 | 缺少 `TerminalChromeAppearance`、Ghostty 解析入口和 model 分发入口 | 按预期失败 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 新 worktree 缺少 GhosttyKit header | 1 | 运行项目 `setup-ghostty.sh` 后取得真实红测结果 |
