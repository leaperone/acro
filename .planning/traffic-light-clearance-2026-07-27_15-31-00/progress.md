# 执行进度：traffic-light-clearance

- 任务 ID：`traffic-light-clearance-2026-07-27_15-31-00`
- 创建时间：`2026-07-27_15-31-00`
- 当前状态：`completed`

## 已完成

- 核对 Beta.28/build 59、main、近 2h UI 日志和现有测试边界。
- 并行对照 cmux 顶部 chrome 与 Acro 全部 traffic-light 调用链。
- 确认全屏空槽和非首窗格 zoom 重叠是两个 High。
- 确认两者共享“固定占位没有跟随真实可见状态”的根因。
- 添加两个行为回归测试，并确认旧实现分别以 `minX = 0` 和 `inset = 80` 失败。
- 主窗口全屏状态通过现有 enter/exit 通知同步到 model，并统一刷新全部缓存 controller。
- zoom 后 leading inset owner 改为当前 zoomed pane；退出 zoom 后恢复 root first pane。
- 完成桌面全量测试、release build、TypeScript 检查与构建、打包及 runtime smoke。

## 进行中

- 无；代码已达到提交与 PR 准备状态。

## 修改文件

- `.planning/traffic-light-clearance-2026-07-27_15-31-00/*`
- 预计修改 `WorkbenchModel.swift`、`WorkbenchView.swift`、vendored `TabBarView.swift` 与交互测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Beta.28 当前运行 | UI/runtime 正常；daemon PID 1151 与 9 个 PTY 保留 | pass |
| 全屏 clearance 调用链 | 只看侧栏状态，不看 fullScreen | fail，确认根因 |
| zoom inset owner | 固定原始 root first pane | fail，确认根因 |
| 标签基础交互 | 点击、排序、分屏与空白拖窗已有绿测 | pass，必须保留 |
| `zoomedNonLeadingPaneKeepsTrafficLightClearance` | 唯一可见标签 `minX = 0`，预期 `>= 80` | expected fail |
| `fullScreenNotificationsUpdateTrafficLightClearance` | enter fullscreen 后 inset 仍为 `80`，预期 `0` | expected fail |
| `TerminalPanesInteractionTests` | 46 个交互测试全部通过 | pass |
| `swift test --package-path apps/desktop-macos` | XCTest 86 个 + Swift Testing 59 个全部通过 | pass |
| `swift build --package-path apps/desktop-macos -c release` | release build 完成；仅既有编译警告 | pass |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | pass |
| `pnpm build` | cli/runtime 构建完成；仅既有 `import.meta` 警告 | pass |
| desktop release scripts | 9 个测试通过 | pass |
| package/runtime smoke | ad-hoc app 签名验证、CLI help、runtime `/health` 通过 | pass |
| daemon 保留 | 原 daemon PID 1151 未重启；UI/runtime PID 56207/56229 未变 | pass |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 初始计划优先处理显示器断开 | 1 | 新的运行态审查发现 2 个直接影响顶部标签的 High；无代码写入前已原地调整 checkout 与 planning |
| 直接给普通 NSWindow 插入 `.fullScreen` 做合成测试会触发 AppKit 异常 | 1 | 不伪造非法 styleMask；首个红测覆盖 zoom 可见 pane，full-screen 通过现有通知链加可测试 model 状态覆盖 |
| 尝试先提交失败测试时 development guard 拒绝未完成 planning | 1 | 不绕过 guard；先完成实现与验证，再按 staged 边界生成“红测 / 修复”两个提交 |
