# 执行进度：native-window-drag

- 任务 ID：`native-window-drag-2026-07-27_14-42-42`
- 创建时间：`2026-07-27_14-42-42`
- 当前状态：`in_progress`

## 已完成

- 核对 main、当前 Beta.27 运行实例与全部 `WindowDragHandle` 调用方。
- 对照最新 cmux 原生 `performDrag` 和旧手工 workaround 历史。
- 证明 `NSWindow.performDrag(with:)` 可用测试子类拦截而不移动真实窗口。
- 独立提交失败测试 `a7606d1`，旧实现真实失败。
- 删除手工坐标跟踪，改为临时启用 `isMovable` 后调用原生 `performDrag`，并用 `defer` 恢复。
- 标签点击、标签排序和分屏按钮的集成路径确认不会触发侧栏拖窗。

## 进行中

- 执行完整 Swift、release 和 workspace 验证。

## 修改文件

- `.planning/native-window-drag-2026-07-27_14-42-42/*`
- 预计修改 `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- 预计修改 `apps/desktop-macos/Sources/WorkbenchView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 只读调用链审查 | 三个侧栏入口共享一个类；标签栏不经过该类 | pass |
| 原生 API 可测试性 | `NSWindow.performDrag(with:)` 可 override | pass |
| 修复前目标测试 | 原生调用次数等 3 项断言失败 | expected fail |
| 修复后目标测试 | 原生拖动、状态恢复、双击 zoom 全部通过 | pass |
| 标签交互隔离 | 点击、排序、分屏后 `performDragCallCount == 0` | pass |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| fresh worktree 缺少 `GhosttyKit/ghostty.h` | 1 | 运行 `setup-ghostty.sh` 后恢复 |
