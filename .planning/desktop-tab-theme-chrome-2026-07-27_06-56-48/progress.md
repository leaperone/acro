# 执行进度：desktop-tab-theme-chrome

- 任务 ID：`desktop-tab-theme-chrome-2026-07-27_06-56-48`
- 创建时间：`2026-07-27_06-56-48`
- 当前状态：`in_progress`

## 已完成

- 对照最新 Acro、cmux 和 vendored Bonsplit 的主题调用链。
- 确认根因是 finalized Ghostty 配置没有传播到 Bonsplit controller。
- 确认全部缓存 controller 的统一更新入口位于 `WorkbenchModel`。
- 增加 Ghostty finalized config 与全部缓存 controller 的红色回归。
- 增加 `TerminalChromeAppearance`，直接读取 Ghostty finalized 背景色和透明度。
- 由 `WorkbenchModel` 将外观应用到现存和后续创建的全部 controller。
- 不透明主题启用 shared backdrop；半透明主题使用单层预合成 chrome。
- 设置热重载和 App 首次出现都会同步主题到工作台。
- 全量 Desktop、TypeScript、构建和 release script 验证通过。

## 进行中

- 提交、推送 PR 并执行 preflight。

## 修改文件

- `Ghostty.swift`、`WorkbenchModel.swift`、`TerminalPaneController.swift`、`WorkbenchView.swift`、`SettingsView.swift`、`AcroApp.swift` 和对应测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码对照 | Ghostty reload 与 Bonsplit appearance 当前断链 | 已确认 |
| 针对性红测 | 缺少 `TerminalChromeAppearance`、Ghostty 解析入口和 model 分发入口 | 按预期失败 |
| 针对性绿测 | finalized config 解析、现存/后建 controller 同步和半透明分支 | 已通过 |
| 全量 Desktop | 81 XCTest + 26 Swift Testing | 已通过 |
| `pnpm check` | TypeScript 与 15 项 Node 测试 | 已通过 |
| `pnpm build` | CLI/runtime 构建；仅现有 import.meta 警告 | 已通过 |
| Desktop release scripts | 7 项通过 | 已通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 新 worktree 缺少 GhosttyKit header | 1 | 运行项目 `setup-ghostty.sh` 后取得真实红测结果 |
