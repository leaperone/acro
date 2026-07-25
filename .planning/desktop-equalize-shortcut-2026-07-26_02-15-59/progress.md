# 执行进度：desktop-equalize-shortcut

- 任务 ID：`desktop-equalize-shortcut-2026-07-26_02-15-59`
- 创建时间：`2026-07-26_02-15-59`
- 当前状态：`complete`

## 已完成

- 已核对主 checkout、现有 worktrees 和无关 dirty 状态。
- 已核对 Acro 全部快捷键入口、均分调用链和现有测试。
- 已对照 cmux 的动作、默认键、菜单入口和均分算法。
- 已创建独立分支 `fix/desktop-equalize-shortcut` 和任务 worktree。
- 已把 `equalizeSplits` 默认键从 `⌥⌘=` 改为 `⌃⌘=`。
- 已增加真实 `NSEvent` 默认键匹配测试。
- 已完成完整桌面测试、全仓 TypeScript check 和本地 ad-hoc 打包。
- 已热替换本机 UI + runtime；daemon PID `1151` 保持不变，runtime 健康检查通过。
- 已完成提交前 diff 复核；改动只包含共享默认键、对应测试和任务记录。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-equalize-shortcut-2026-07-26_02-15-59/task_plan.md`
- `.planning/desktop-equalize-shortcut-2026-07-26_02-15-59/findings.md`
- `.planning/desktop-equalize-shortcut-2026-07-26_02-15-59/progress.md`
- `apps/desktop-macos/Sources/ShortcutSettings.swift`
- `apps/desktop-macos/Tests/ShortcutSettingsTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 项目基线 | `leaperone-dev-init --check/init` 通过 | 通过 |
| Acro / cmux 调用链 | 已由主 agent 对照源码复核 | 通过 |
| 新增测试（修复前） | `⌃⌘=` 不匹配，实际为 `⌥⌘=`；2 个断言失败 | 按预期失败 |
| 新增测试（修复后） | `swift test --filter ShortcutSettingsTests/testEqualizeSplitsDefaultMatchesCmux` | 通过 |
| 桌面完整测试 | `swift test` | 75 个 XCTest + 7 个 Swift Testing 测试全部通过 |
| 全仓静态检查 | `pnpm check` | protocol、runtime、cli、mobile 全部通过 |
| 本地打包 | `package-app.sh 0.0.8-beta.13 43` | release build、CLI/runtime bundle、codesign、zip/dmg 全部通过 |
| 本机热替换 | UI `41342` + runtime `41583` 使用本任务 app；daemon `1151` 未重启 | 通过 |
| runtime 健康 | `GET http://127.0.0.1:8790/health` | `{"ok":true,"name":"acro-runtime"}` |
| 真实截图级 UI | 两套 Computer Use 均无法获取 Acro 隐藏标题栏窗口 | 未完成，非功能阻断 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| worktree 脚本远端 fetch 无输出 | 1 | 改用已核对的 `origin/main` SHA 作为固定 base，脚本成功创建 worktree。 |
| Swift 测试构建缺少 `GhosttyKit/ghostty.h` | 1 | 运行仓库自带 `scripts/setup-ghostty.sh`，固定资源校验通过后重新运行。 |
| Computer Use 报无 Accessibility window / `cgWindowNotFound` | 2 | 权限检查为 granted；停止重复尝试，记录 UI 验证边界。 |
