# 调研与结论：native-window-drag

- 任务 ID：`native-window-drag-2026-07-27_14-42-42`
- 创建时间：`2026-07-27_14-42-42`

## 需求事实

- Beta.27 已修复顶部标签命中和 32pt 空区；当前剩余的明确 cmux 差异是侧栏标题栏空白区仍手工移动窗口。
- Apple 直接操作原则要求拖动连续、可中断并继承系统窗口管理语义。

## 真实调用链

- `SidebarView` 有两个 `WindowDragHandle`：62pt 红绿灯区与右侧控件前的弹性空白区。
- `CompactSidebarView` 顶部 header 整体使用 `WindowDragHandle`。
- 三个入口都进入 `WindowDragNSView.mouseDown/mouseDragged/mouseUp`；终端标签空白拖窗走 Bonsplit 的独立原生路径。

## 调研结论

- 手工 `NSEvent.mouseLocation` + `setFrameOrigin` 绕过 AppKit 原生 drag session。
- 因此系统边缘平铺/吸附预览、zoomed-window drag-to-restore、全屏约束和丢失 mouseUp 时的中断清理由 Acro 自己承担，当前实现没有完整覆盖。
- 旧提交 `8a2784a` 因 `isMovable=false` 让 `performDrag` 成为 no-op，才引入手工 workaround；cmux `aac2351` 已用临时恢复 movable 解决同一问题。
- `NSWindow.performDrag(with:)` 可被测试子类 override，不需要新增产品 seam 或真实移动测试机窗口。
- 旧实现运行回归测试时，原生调用次数、原始事件和调用期间 movable 三项断言都会失败；不是只靠源码对照推断。
- 最终审查确认，首次 `mouseDown` 立即进入 `performDrag` 会让 AppKit 可能吞掉首击 `mouseUp`；Acro 没有 cmux 的双击 monitor，必须复用 Bonsplit 的 4pt 阈值后启动拖动模式。

## 技术决策

| 决策 | 证据 |
|---|---|
| 先用 spy window 验证原生调用 | 当前实现 callCount 为 0，修复后可同时验证调用期间与返回后的 movability |
| 删除手工坐标移动 state | 原生 session 已管理连续跟踪和中断，保留窗口原点计算会重复实现平台能力 |
| 保留最小 pending down state | 只用于区分点击与拖动并把原始 mouseDown 交给 AppKit；不是重新实现窗口坐标移动 |

## 风险与边界

- `mouseDownCanMoveWindow` 必须继续返回 false，避免 AppKit 隐式拖窗再次抢走标签 mouseUp。
- 标题栏双击系统偏好是独立行为差异，本增量不扩大范围。
- 无 Computer Use/XCUITest；使用不移动真实窗口的 AppKit spy 行为测试。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `.tmp/cmux/Sources/WindowDragHandleView.swift`
- `8a2784a`、`863edcd`
