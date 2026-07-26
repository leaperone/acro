# 执行进度：desktop-window-chrome-integration

- 任务 ID：`desktop-window-chrome-integration-2026-07-27_02-34-59`
- 创建时间：`2026-07-27_02-34-59`
- 当前状态：`complete`

## 已完成

- 核对 beta.19 运行进程、runtime health、main/release/appcast 状态。
- 对照 Acro、cmux 和两份 Bonsplit vendor，确认标签算法同源。
- 确认 minimal mode 未接入和全屏 inset 缺失是 host 层根因。
- 创建独立任务 worktree 并校验项目基线。
- 两次候选修复均在真实运行实例暴露顶部空区并已全部撤回。
- 两次错误候选验证后都已切回主仓原版 beta.19，再基于截图和 AppKit frame 实现最终方案。
- 按截图定位到 WindowGroup/HSplitView 重复标题栏安全区，并实现动态抵消。
- 热替换最终任务 build；daemon PID 1151 保持，runtime health 正常。
- 通过 LLDB 读取最终运行窗口：titlebar=32、safeAreaTop=32；NSSplitView y=0，两个标签栏 y=1005 height=28，顶边精确等于窗口高度 1033。

## 进行中

- 无。

## 修改文件

- `.planning/desktop-window-chrome-integration-2026-07-27_02-34-59/*`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro/cmux Bonsplit 核心文件对比 | 逐字节一致 | 通过 |
| 真实窗口枚举 | Acro 1904×1033 窗口存在 | 通过 |
| Computer Use / 窗口截图 | Orca 未运行；系统拒绝像素捕获 | 未执行 |
| `swift test --filter TerminalPanesInteractionTests` | 9 项通过 | 通过 |
| Acro Desktop `swift test` | 78 XCTest + 16 Swift Testing 通过 | 通过 |
| Bonsplit `swift test` | 202 项通过 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | workspace build 通过；仅既有 import.meta 警告 | 通过 |
| Desktop `swift build -c release` | 通过；仅既有 vendor/Updater 警告 | 通过 |
| `package-app.sh 0.0.8-beta.19 50` | zip/dmg 生成成功 | 通过 |
| 本机热替换 | UI/runtime 更新，daemon PID 1151 保持，8790 health 正常 | 通过 |
| 错误候选回滚 | `workspacePresentationMode` 已删除，产品代码无残留 | 通过 |
| `CompactSidebarTests` | 7 项通过，覆盖 titlebar/safe-area/fullscreen/clamp | 通过 |
| Acro Desktop `swift test` | 79 XCTest + 16 Swift Testing 通过 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | workspace build 通过；仅既有 import.meta 警告 | 通过 |
| 最终运行窗口指标 | tab 顶边=1033，与 window height=1033 一致；split bottom y=0 | 通过 |
| 本机热替换 | UI PID 38924、runtime PID 38929、daemon PID 1151、8790 health 正常 | 通过 |
| 稳定签名热替换 | UI PID 93270、runtime PID 93325、daemon PID 1151；Developer ID Team 5UAHRS482C | 通过 |

## 交付前收敛

- 最终 diff 只包含窗口 safe-area 根因修复、边界测试和本任务 planning。
- 两次无效候选实现与对应 UserDefaults 已完全撤回。
- 真实 AppKit frame、自动化测试、构建和本机热替换均覆盖验收标准。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Orca runtime unavailable | 1 | 按项目规则停止重试，继续源码/构建证据 |
| cmux pull DNS 失败 | 1 | 不修改参考仓，记录基线边界 |
| worktree 脚本无法 fetch origin/main | 1 | 已确认本地 `origin/main == main`，先固定本地分支后由原脚本创建 worktree |
| 首次编译找不到 `WindowDragHandle` | 1 | 恢复仍被 wide/compact 侧栏使用的手柄，限定 Bonsplit minimal 只接管终端顶部 |
| 用户确认第一次候选出现顶部空区 | 1 | 撤回全局 minimal、删除 defaults、热替换恢复版 |
| 用户确认第二次候选仍有顶部空区 | 1 | 撤回全部产品代码并切回主仓原版 beta.19 |
