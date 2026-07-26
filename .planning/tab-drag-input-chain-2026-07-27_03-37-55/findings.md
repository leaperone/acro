# 调研与结论：tab-drag-input-chain

- 任务 ID：`tab-drag-input-chain-2026-07-27_03-37-55`
- 创建时间：`2026-07-27_03-37-55`

## 需求事实

- 用户明确反馈顶部标签之间无法拖动排序。
- Acro 已开启 `allowTabReordering` 和 `allowCrossPaneTabMove`，Bonsplit 版本与 cmux 最新 main 相同。

## 真实调用链

- `TabBarManualReorderTrackingView` 用本地 NSEvent monitor 接收 down/drag/up。
- 起点和落点由 `TabBarItemGeometryRegistry` 的真实 AppKit 标签 frame 计算。
- 排序成功后通过 `didReorderTabsInPane` 回调 `TerminalPaneController.persist`。
- 当前 Acro 测试只执行 `controller.reorderTab`，跳过了 monitor、坐标转换和标签 frame。

## 调研结论

- 不能从配置和模型测试推断真实拖拽可用。
- PR #122 只改变宿主顶部 safe-area，需要通过真实窗口坐标测试排除坐标错位。
- 新增的真实窗口测试已证明完整链路可用：本地 NSEvent monitor 收到 down/drag/up，Bonsplit 执行 targetIndex=3 的 drop，工作区布局持久化为 `2,3,1`。
- 在 `fullSizeContentView`、`window.isMovable=false` 和 `-32pt` 顶部补偿同时存在时仍通过，因此 PR #122 没有造成标签 frame 与 window 坐标错位。
- 当前产品实现不需要重写；保留一条宿主级回归测试即可防止未来退化成“API 能重排、鼠标不能重排”。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用真实 NSWindow + NSHostingView + NSEvent | 覆盖用户实际输入链，且不依赖不可用的桌面自动化 |
| 先测试再决定是否改产品 | Bonsplit 算法已同源，避免无证据复制或重写 |

## 风险与边界

- Computer Use 当前不可用，不能声明完成了真实人工指针验收。
- 测试必须使用标签真实 frame，不能硬编码假坐标后只验证数据层。
- `BonsplitTabItemHitRegionProviding` 同时包含整条标签栏背景和单个标签区域；测试只选择窄于宿主一半的真实标签 item，避免把背景当作拖拽起点。

## 参考指针

- `TerminalPanesInteractionTests.swift:24-42`
- `Vendor/Bonsplit/.../TabBarView.swift:1985-2166`
- `.tmp/cmux` HEAD `aac23518`，Bonsplit gitlink `48643102`
