# 任务计划：terminal-first-click-focus

- 任务 ID：`terminal-first-click-focus-2026-07-27_17-31-21`
- 创建时间：`2026-07-27_17-31-21`

## 目标

让终端正文的左键遵循 cmux 的安全聚焦语义：后台窗口首次点击只激活窗口；已激活窗口点击未聚焦窗格时只切换焦点；只有点击前已经聚焦的终端才接收 Ghostty 左键事件。

## 范围

- `AcroTerminalNSView` 的 first-mouse 与左键转发边界。
- `TerminalPanesView` 已知的 pane focused 状态向终端视图传递。
- 覆盖后台窗口、未聚焦窗格、已聚焦终端和无孤立 release/drag 的行为测试。

## 非目标

- 不改变顶部标签栏、first-mouse 顶部控件或任何视觉布局。
- 不改变右键、中键和滚轮语义。
- 不新增设置项；采用 cmux 当前运行时默认的安全行为。
- 不修改 Ghostty 渲染、键盘输入或远程会话协议。

## 关键约束

- 修复共享终端 NSView 根因，不在 SwiftUI pane 外层拦截鼠标。
- 判断必须基于 pointer-down 前的 pane focused 状态，不能在 `mouseDown` 内查询已经更新后的焦点。
- focus-only 点击不得设置 pending left release，也不得继续转发 drag。
- 回归修复使用两提交：先失败测试，再实现。

## 修改路径

- `apps/desktop-macos/Sources/AcroTerminalView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 在旧实现运行新增测试，确认默认 accepts first mouse 与 focus-only 契约失败。
- 运行针对性 Swift 测试、Acro 桌面完整测试和 release 构建。
- 用两个窗格和另一个前台应用验证：第一次只激活；第二次只聚焦未聚焦 pane；之后点击才操作终端。
- 发布 Beta 后热替换 UI/runtime，确认 daemon PID 和原有会话不变。

## 验收标准

- 后台 Acro 第一次点击终端正文不会改变 pane 焦点或操作 TUI。
- Acro 已激活时，第一次点击另一个 pane 只切换 pane 焦点，不操作 TUI。
- 已聚焦终端的正常点击、拖选和 mouseUp 配对保持工作。
- 顶部标签栏和分屏控件仍保持 Beta.30 的首次点击行为。
- 自动化测试、构建、CI、发布和本机安装验证通过。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 默认不接受终端正文 first mouse | cmux 运行时默认 false，避免激活窗口时顺便操作 TUI |
| 未聚焦 pane 的左键只聚焦 | cmux 在 pointer-down 前快照焦点，防止 pane 切换与 TUI 操作绑定在同一击 |
| 不新增可选开关 | Acro 当前没有对应设置需求，安全默认已解决真实误操作，避免投机扩展 |
| 右键和滚轮保持现状 | 它们有不同的 macOS 与终端语义，需要独立产品契约 |
| 用单一状态机维护左键配对 | press、drag、release 共用同一 pending 状态，测试可直接证明 focus-only 手势不会进入 Ghostty |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无需恢复 |
