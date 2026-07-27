# 执行进度：desktop-terminal-loading-state

- 任务 ID：`desktop-terminal-loading-state-2026-07-27_12-37-51`
- 创建时间：`2026-07-27_12-37-51`
- 当前状态：`complete`

## 已完成

- 确认布局恢复、空 pane 创建和 Runtime 快照三条调用链。
- 确认根因是视图状态折叠，而非 session 生命周期错误。
- 主 agent 复核 subagent 反例：`session.create` 返回到 refresh 提交之间仍无 runtime session，必须显式保留 pending creation。
- 完成 loading placeholder、三态内容映射、Runtime 连接提示和三语言本地化。
- 增加创建 pending→alive 原地收敛、创建失败清理和纯状态映射测试。
- 修复创建 RPC 已返回后关闭标签的竞态：立即隐藏取消的 session，删除失败保留 tombstone，后续快照自动重试。
- 增加旧快照缺失不能提前清 tombstone 的回归测试。
- 创建独立 worktree 并校验项目基线。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-terminal-loading-state-2026-07-27_12-37-51/*`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Localization/{en,ja,zh-Hans}.lproj/Localizable.strings`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 调用链审计 | 未加载快照与空 pane 均落入“终端已结束” | 已确认根因 |
| `setup-ghostty.sh` | GhosttyKit 与资源准备完成 | 通过 |
| `swift test --filter TerminalPanesInteractionTests` | 38 项通过 | 通过 |
| 三语言 `.strings` `plutil -lint` | en/ja/zh-Hans 全部通过 | 通过 |
| 最终 `swift test --filter TerminalPanesInteractionTests` | 39 项通过 | 通过 |
| 最终 `swift test` | 87 XCTest + 55 Swift Testing，共 142 项通过 | 通过 |
| 最终 `swift build -c release` | 完成；仅有既有 Vendor/Updater 警告 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | runtime/cli 完成；仅有既有 `import.meta` CJS 警告 | 通过 |
| 本地化键集合比较 | en/ja/zh-Hans SHA-256 一致 | 通过 |
| 新增 bare English SwiftUI 搜索 | 无结果 | 通过 |
| `git diff --check` | 无错误 | 通过 |
| 最新 `swift test --filter TerminalPanesInteractionTests` | 42 项通过 | 通过 |
| 最终只读 correctness 审查 | Critical / High / Medium / Low 均清零 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 从仓库根运行 `swift test` 找不到 `Package.swift` | 1 | 改到 `apps/desktop-macos` 运行 |
| 新回归测试直接调用 Bonsplit `closeTab` 被活终端关闭守卫拒绝 | 1 | 改走真实 `WorkbenchModel.requestKillTab` 用户路径 |
