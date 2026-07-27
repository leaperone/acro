# 调研与结论：desktop-attach-transport-exit

- 任务 ID：`desktop-attach-transport-exit-2026-07-27_10-37-11`
- 创建时间：`2026-07-27_10-37-11`

## 需求事实

- daemon 持有 PTY；桌面 surface 只运行 `acro attach` 传输桥。
- 网络断线不应改变服务端 Session 与本地布局事实。

## 真实调用链

- CLI attach 重连最多 15 次，耗尽后 `process.exit(1)`。
- Ghostty `wait_after_command=false`，子进程退出触发 `surfaceDidRequestClose()`。
- `TerminalPanesView` 当前无条件调用 `WorkbenchModel.closeTab`。
- `closeTab` 立即删除 Bonsplit 标签、持久布局与自定义标题，即使 Runtime 快照仍显示 Session alive。
- Runtime 已保留断线前完整快照；恢复后 `reconcileLayoutState` 能按服务端 alive 状态清理或保留布局。

## 调研结论

- 根因是“本地传输进程生命周期”和“远端 Session 生命周期”共用关闭通道。
- 最小根修是：surface 退出只判断是否应重启，不再直接删除布局。
- Session 真正结束时，现有 snapshot revision 与 reconcile 已是权威清理路径。
- Ghostty close callback 的布尔值表示是否需要关闭确认，不能证明关闭来源；Acro 的显式关闭继续只走 Bonsplit、菜单和快捷键的 `requestKillTab` 路径。
- Acro 强制 `confirm-close-surface = always`，且在用户递归 include 之后最后加载 overlay；因此 callback 的 true 表示活进程上的显式关闭请求，false 表示 child 已退出。
- Ghostty `close_tab:this` 路由 Acro 当前标签终止入口；`other/right` 与 `close_window` 不交给 Ghostty 的单 surface fallback，避免终止错误 Session。

## 技术决策

| 决策 | 证据 |
|---|---|
| 活会话 surface 延迟重建 | 避免瞬时退出形成紧密重启循环 |
| 缓存中保留同一 NSView | 防止 SwiftUI 重建时出现第二个 surface |
| 服务器不存在时不重启 | 用户移除服务器后不应继续后台连接 |
| 延迟期间设置 restart gate 并二次读取 alive | 阻止 layout/view 回调提前重建，也避免已结束会话复活 |
| surface 退出先等待一次 Runtime refresh | 主连接可用时先获取权威 Session 状态，断线时才保守保留旧布局 |

## 风险与边界

- Session 退出事件与 surface close 顺序可能竞态；alive 快照短暂为真时允许重启一次，随后 reconcile 会清理。
- 不用 surface exit code判断 Session 状态；普通非零退出也可能只是传输失败。
- GhosttyKit 在 XCTest 内真实解析临时递归 include 会崩溃；改用纯加载步骤测试，生产 API 由完整 debug/release 构建覆盖。

## 参考指针

- `apps/cli/src/cli.ts:293-466`
- `apps/desktop-macos/Sources/AcroTerminalView.swift:102,131-143`
- `apps/desktop-macos/Sources/TerminalPanesView.swift:98-119`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:786-803,1517-1620`
