# 任务计划：bonsplit-tab-accessibility

- 任务 ID：`bonsplit-tab-accessibility-2026-07-27_18-16-26`
- 创建时间：`2026-07-27_18-16-26`

## 目标

让 macOS 辅助功能系统正确识别顶部标签及其操作：标签以动态标题命名并暴露选中状态，关闭按钮独立可达，新建终端与分屏按钮使用明确、已本地化的动作名称。

## 范围

- Vendored Bonsplit 最终标签包装的 Accessibility 语义。
- 标签关闭按钮与顶部 split action 按钮的名称、角色和稳定标识。
- Acro 新建终端、向右分屏、向下分屏三项文案的 en/ja/zh-Hans 本地化。
- 正式候选应用的真实 Accessibility tree 验证。

## 非目标

- 不改变标签视觉、尺寸、拖拽、点击、关闭确认或分屏行为。
- 不重做 Bonsplit Accessibility 架构，不引入原生 tab role。
- 不在同一改动处理隐藏侧边栏恢复入口或其他 UI 审查项。
- 不修改 cmux 参考目录。

## 关键约束

- 修复最终对外 AX 元素，不能只给被外层 `.onDrag/.onDrop` 包装吞掉的内层视图重复加 label。
- 标签根元素不能吞掉 close、audio、zoom 等独立操作按钮。
- 不添加无法读取 SwiftUI 虚拟 AX 节点的假单测；真实 AX tree 作为本任务硬验收。
- 所有新增用户可见/可朗读文案必须覆盖 en、ja、zh-Hans。

## 修改路径

- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Resources/*/Localizable.strings`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Localization/*/Localizable.strings`

## 验证方式

- 用 Orca Computer Use 的真实 AX tree 证明 Beta.31 当前的标签、关闭和普通 split action 名称缺失。
- 运行 Bonsplit 针对性测试、Bonsplit 完整测试、Acro 完整 Swift 测试与 release 构建。
- 运行本地化 key 对齐与 strings 语法检查。
- 打包候选版并用 Orca Computer Use 读取真实 Beta Accessibility tree，确认标签与按钮名称。

## 验收标准

- 每个标签的最终 AX button 名称等于 `tab.title`，选中标签保持 selected 状态。
- close 是独立 AX button，名称明确且不与标签根元素重复。
- new terminal、split right、split down 的 AX 名称非空且与当前语言一致；identifier 保持不变。
- 标签点击、拖拽排序、关闭、分屏和顶部 first-mouse 不回归。
- 自动化测试、构建和真实 Beta Accessibility tree 验证通过。

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
| 修复 Vendored Bonsplit 共享组件 | 所有终端/浏览器标签与内建动作都走同一组件，宿主逐项补 label 会遗漏 future/custom actions |
| 保留 Button role + selected trait | 与 cmux/Bonsplit 现有语义一致，不扩展为未验证的原生 tab role |
| 关闭按钮独立暴露 | 它是单独可执行动作，不能被标签根的 children combine 吞掉 |
| 不保留同进程 AX 假测试 | SwiftUI 虚拟 AX 节点不出现在 `NSHostingView.accessibilityChildren()`，无法区分修复前后 |
| 先不处理隐藏侧栏入口 | 它是独立 wayfinding 议题，与 AX 根因无共同修改点 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 紧凑侧栏截图一度显示大块空白 | 1 | 复查确认只是 180ms 收缩动画中间帧，稳定态宽度正确，未做误修 |
