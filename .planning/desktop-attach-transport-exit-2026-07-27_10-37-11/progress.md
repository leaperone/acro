# 执行进度：desktop-attach-transport-exit

- 任务 ID：`desktop-attach-transport-exit-2026-07-27_10-37-11`
- 创建时间：`2026-07-27_10-37-11`
- 当前状态：`completed`

## 已完成

- 复核 CLI、Ghostty surface、布局删除和 Runtime 对账调用链。
- 确认当前只有一套 UI/runtime/daemon，且本轮不能重启 daemon。
- 新增两态 surface 退出策略：活会话重建传输，死会话权威清理。
- attach 异常退出不再调用 `closeTab`；活会话延迟重建同一缓存 surface。
- 新增活会话保留布局/自定义标题、死会话对账清理和缓存生命周期测试。
- surface 退出先等待 Runtime refresh；可达时以新快照判断，不可达时保守重建传输。
- Ghostty 显式 close action 独立进入 Acro `requestKillTab`；close mode 不会误杀当前 Session。
- Acro overlay 最后加载并强制 `confirm-close-surface = always`，稳定区分显式关闭和 child exit。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-attach-transport-exit-2026-07-27_10-37-11/*`
- `apps/desktop-macos/Sources/Ghostty.swift`
- `apps/desktop-macos/Sources/SettingsView.swift`
- `apps/desktop-macos/Sources/AcroTerminalView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Tests/TerminalAppearanceTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码调用链审计 | transport exit 无条件进入 closeTab | 通过 |
| 新增针对性 Swift 测试 | 3 个测试通过 | 通过 |
| Desktop 全量测试 | 83 XCTest + 46 Swift Testing | 通过 |
| Swift release build | `swift build -c release` | 通过 |
| Workspace check | `pnpm check` | 通过 |
| Workspace build | `pnpm build` | 通过，只有既有 import.meta 警告 |
| 独立 diff 审查 | 未发现剩余 correctness 问题 | 通过 |
| 真实 UI 自动化 | Orca runtime 与原生截图不可用 | 未执行，不阻断 |
| 最终提交前复验 | 83 XCTest + 46 Swift Testing、release build、pnpm check/build、diff check | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| zsh 对不存在的 `apps/cli/test*` 直接报错 | 1 | 改用 rg 的文件类型过滤 |
| 新 worktree 缺少 `GhosttyKit/ghostty.h` | 1 | 运行项目现有 `setup-ghostty.sh` 补齐依赖 |
| 首版 fixture 未显式设置 selectedSessionId | 1 | 设置初始选中值后验证状态保持 |
| GhosttyKit 在 XCTest 中解析临时递归 include 崩溃 | 1 | 改测纯加载步骤顺序；完整构建覆盖真实 API |
