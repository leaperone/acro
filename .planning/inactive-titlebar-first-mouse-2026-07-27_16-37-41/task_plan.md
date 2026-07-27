# 任务计划：inactive-titlebar-first-mouse

- 任务 ID：`inactive-titlebar-first-mouse-2026-07-27_16-37-41`
- 创建时间：`2026-07-27_16-37-41`

## 目标

让非激活 Acro 窗口的顶部标签栏控件在第一次鼠标操作时同时激活窗口并完成原动作，保持正文和其他普通内容的现有 first-mouse 边界。

## 范围

- 顶部标签选择、关闭、缩放与拖拽排序。
- 新终端、向右分屏、向下分屏按钮。
- 标签栏空白拖窗区和侧栏标题拖窗区。
- 覆盖上述语义的 AppKit 行为回归测试。

## 非目标

- 不改变顶部标签栏高度、间距、红绿灯避让或任何视觉布局。
- 不改变终端正文第一次点击是否转发给 TUI 的现有产品策略。
- 不给整个 Workbench 窗口开放 first mouse。
- 不引入新依赖或新的命中区域抽象。

## 关键约束

- 复用现有 `BonsplitTabBarHitRegionRegistry`，只让已登记的可见标签栏区域接受 first mouse。
- 保留现有关闭确认、标签拖拽阈值、双击缩放和原生窗口拖动行为。
- 参考 cmux 的局部标题栏命中策略，但不机械复制其尚未覆盖的 Bonsplit 行为。
- 回归修复先提交失败测试，再提交实现。

## 修改路径

- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/SplitNodeView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/TabBarView.swift`（仅在最深层拖窗视图需要显式 first mouse 时修改）
- `apps/desktop-macos/Sources/AcroDesktop/WorkbenchView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 在旧实现上运行新增测试，确认标签栏区域和拖窗区域的 first-mouse 断言失败。
- 运行新增的针对性 Swift 测试。
- 运行桌面端完整测试与 release 构建。
- 使用两个窗口真实验证第一次点击标签、分屏和拖窗。
- 发布 Beta 后热替换 UI/runtime，确认 daemon PID 不变和终端会话仍在。

## 验收标准

- 非 key 窗口第一次点击标签或顶部动作即可执行，不需要第二次点击。
- 非 key 窗口第一次拖动标签或空白标题区即可开始对应拖动。
- 标签栏外普通 SwiftUI 内容不会因本修复直接执行 first mouse。
- 顶部布局与 Beta.29 保持一致。
- 自动化测试、构建、CI、发布和本机安装验证通过。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 在 Bonsplit hosting view 按现有标签栏 registry 判断 | 一处覆盖标签、关闭和普通 SwiftUI 分屏按钮，同时不扩大到正文 |
| 原生拖窗子视图显式接受 first mouse | AppKit 以最深命中视图决定事件是否送达，拖窗视图需要保持首次手势完整 |
| 不改终端正文策略 | 这是独立产品选择，不属于顶部交互缺陷 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| | 1 | |
