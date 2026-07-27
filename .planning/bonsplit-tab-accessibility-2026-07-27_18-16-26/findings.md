# 调研与结论：bonsplit-tab-accessibility

- 任务 ID：`bonsplit-tab-accessibility-2026-07-27_18-16-26`
- 创建时间：`2026-07-27_18-16-26`

## 需求事实

- Beta.31 实际 Accessibility tree 中，肉眼可见 `Ready | main` 的标签只暴露为无名称 selected button。
- 标签关闭按钮、new terminal、split right、split down 也缺少明确 AX 名称。
- Wide、Compact、Hidden 三种侧栏稳定布局均正确；紧凑态空白是动画中间帧，不是布局 bug。

## 真实调用链

- `TerminalPaneController` 把动态终端标题写入 Bonsplit Tab，`TabItemView` 正常渲染 `Text(tab.title)`。
- `TabItemView` 内层已有 label/value/selected trait，但 `TabBarView.tabItem` 在外层继续叠加 drag/drop/hit-region，最终 AX button 没有继承内层名称。
- split action 的 mouse-down 分支有 label，普通 SwiftUI `Button` 分支只有 tooltip 与 identifier，没有 accessibility label。
- close xmark 是独立 Button，但没有 label/identifier，且可能被 tab root 的 `.combine` 吞掉。

## 调研结论

- 标签数据没有缺失；根因是最终 Bonsplit 组合层没有稳定输出 AX 语义。
- cmux vendored Bonsplit 同样存在 close 与 split action 缺口，不能直接照抄其当前实现。
- 修复应绑定在最终 tab 包装和共享 action/close 控件，覆盖 terminal、browser、pinned 与未来 custom action。
- SwiftUI 虚拟 AX 节点由系统 Accessibility 服务导出；同进程 `NSHostingView.accessibilityChildren()` 只返回空 group，不能作为可靠回归测试。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用正式候选应用的真实 AX tree | 现有鼠标命中测试无法证明 VoiceOver 实际读到名称，同进程测试又无法读取 SwiftUI 虚拟节点 |
| 动作 label 复用 tooltip 语义 | Acro 已定义具体动作名称，避免 SF Symbol 自动推导含糊名称 |
| 文案同时本地化 | Accessibility label 属于用户可见界面，不能只在中文系统正确 |

## 风险与边界

- 外层 accessibility modifier 可能合并 close/audio/zoom 子按钮；测试必须验证子操作仍独立。
- `.accessibilityRepresentation` 可能改变拖拽/点击命中，不作为首选方案。
- 当前任务只修已确认的顶部标签 AX 语义，不顺手重构本地化体系。
- 自动化无法直接读取 SwiftUI 最终 AX tree；候选包必须用 Orca Computer Use 做真实树验收。

## 参考指针

- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `.tmp/cmux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/`
