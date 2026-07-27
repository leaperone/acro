# 调研与结论：terminal-first-click-focus

- 任务 ID：`terminal-first-click-focus-2026-07-27_17-31-21`
- 创建时间：`2026-07-27_17-31-21`

## 需求事实

- Acro 当前 `AcroTerminalNSView.acceptsFirstMouse` 无条件返回 true。
- 用户只是激活后台窗口时，左键会进入 `mouseDown`，同时聚焦终端、聚焦 pane 并向 Ghostty/TUI 发送真实 press。
- cmux 当前运行时默认 `PaneFirstClickFocusSettings.defaultEnabled = false`。
- 即使 cmux 允许后台窗口一次聚焦 pane，点击前未聚焦的 pane 也不会在同一击转发到终端。

## 真实调用链

- `AcroTerminalNSView.mouseDown` 当前依次调用 `focusTerminal`、`forwardMouseButton`、`onFocus`。
- `forwardMouseButton` 会先发送鼠标坐标，再调用 `ghostty_surface_mouse_button(PRESS, LEFT)`。
- `onFocus` 在 `TerminalPanesView` 调用 `paneController.controller.focusPane(paneId)`。
- `TerminalPanesView` 已经计算 `focused`，但当前没有传入 `AcroTerminalView`。
- `mouseUp` 通过 `leftMousePressed` 配对 release；`mouseDragged` 当前不检查 pending press。

## 调研结论

- 当前行为会在 tmux/vim/nvim/less 等启用鼠标报告的 TUI 中移动光标、切换区域或触发按钮，也可能改变 Ghostty 文本选择。
- 只把 `acceptsFirstMouse` 改成 false 只能修复后台窗口，不能修复当前窗口内点击未聚焦 pane 的误操作。
- 完整根修需要把 pointer-down 前的 pane focused 状态传给终端，并在 focus-only 点击上抑制 press、drag 和 release。

## 技术决策

| 决策 | 证据 |
|---|---|
| 共享修复在 `AcroTerminalNSView` | 所有终端左键最终都经过该类，外层补丁会遗漏缓存 surface 或复制规则 |
| 使用 pane focused 状态，不使用 `window.isKeyWindow` | 到 `mouseDown` 时窗口可能已经激活；窗口状态无法区分未聚焦 pane |
| `mouseDragged` 只在 pending press 时转发 | focus-only 点击不能向 TUI 产生没有 press 的拖动坐标流 |

## 风险与边界

- 双击未聚焦 pane 时，第一击只聚焦，后续点击才可能形成终端选择；这是安全取舍并与 cmux 一致。
- `acceptsFirstMouse` 可能影响右键的 AppKit 投递，但本轮不修改右键实现；需要行为测试后另定契约。
- 滚轮不走 first-mouse 左键链，本轮保持后台滚动现状。

## 验证结论

- 新增测试在旧实现稳定失败：终端正文仍接受 inactive-window first mouse。
- 修复后针对性 3 项测试通过。
- Acro 桌面完整测试通过：XCTest 86 项、Swift Testing 63 项。
- `swift build -c release` 通过。
- 候选 `0.0.8-beta.31` build 62 已打包并热替换 UI/runtime；daemon PID 1151 保持不变。
- 真实 UI 验证通过：后台窗口首次点击终端正文只激活；当前窗口点击未聚焦 pane 只聚焦；两步均未改变 TUI prompt。
- 已聚焦终端允许正常左键由策略测试覆盖；未在敏感 TUI 控件上做破坏性点击。
- 最终审查发现原测试只覆盖 press 决策，没有直接锁定 drag/release 配对；实现已收敛为 `PrimaryPointerState`，同一状态机管理 press、drag、release，并用事件序列测试覆盖 focus-only 与正常手势。
- `isFocusedPane` 闭包不会形成循环引用：`TerminalPaneController` 对 `WorkbenchModel` 是弱引用，Bonsplit delegate 也是弱引用；闭包每次读取当前 controller，不会固化 restore 前快照。
- 本分支未修改顶部标签栏入口，Beta.30 的顶部 first-mouse 行为保持不变。

## 参考指针

- Acro：`apps/desktop-macos/Sources/AcroTerminalView.swift`
- Acro：`apps/desktop-macos/Sources/TerminalPanesView.swift`
- Acro：`apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- cmux：`.tmp/cmux/Sources/GhosttyTerminalView.swift`
- cmux：`.tmp/cmux/Sources/GhosttyNSView+PointerFocusActivation.swift`
- cmux：`.tmp/cmux/Sources/TerminalPointerFocusActivationPolicy.swift`
- cmux：`.tmp/cmux/Sources/App/WorkspaceRuntimeSettings.swift`
