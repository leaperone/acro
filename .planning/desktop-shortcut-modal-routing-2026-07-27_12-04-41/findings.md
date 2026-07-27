# 调研与结论：desktop-shortcut-modal-routing

- 任务 ID：`desktop-shortcut-modal-routing-2026-07-27_12-04-41`
- 创建时间：`2026-07-27_12-04-41`

## 需求事实

- Acro 的应用级 local monitor 在 SwiftUI 控件和菜单之前处理 keyDown。
- 当前命中任何应用快捷键都会立即发通知并返回 `nil`。
- 命令面板是主窗口内 overlay；Alert、confirmationDialog 与服务器 Sheet 还包含模型和本地状态两类来源。

## 真实调用链

- `NSEvent.addLocalMonitorForEvents` → `ShortcutSettings.action/workspaceDigit/tabDigit` → 通知 → `WorkbenchModel.perform/select*`。
- 监听器不读取命令面板、Alert、Sheet、modalWindow 或 first responder 状态。
- 因此 `⌘W` 会先触发 `requestKillFocusedTab`，弹层拿不到原始事件。

## 调研结论

- 根因在全局监听器缺少 presentation-aware routing，而不是某一个弹框。
- 只检查 NSTextField/NSTextView 会漏掉命令面板 FocusState 尚未落位的窗口。
- 命令面板不能简单 `return event`；SwiftUI 菜单快捷键仍可能执行底层动作。
- cmux 使用 execute/consume/pass 三态，并把 visible、pending-open、overlay、responder 合并成有效展示态。
- AppKit Sheet/NSPanel 的事件交给系统后，SwiftUI Commands 仍可能触发菜单通知；模型 guard 必须把当前 AppKit 展示态也纳入同一个权威判断。
- Swift Package 测试进程中 `NSApp` 可能尚未初始化；共享模型判断使用 `NSApplication.shared`，避免隐式解包崩溃。

## 技术决策

| 决策 | 证据 |
|---|---|
| 命令面板中的 app shortcut 返回 consume | 阻止穿透菜单和工作台，同时保留普通输入和编辑键 |
| 系统弹层返回 passToSystem | 原生 default/cancel/窗口行为必须继续工作 |
| 模型动作入口再次 guard | 防止菜单点击或 monitor 与状态切换竞态绕过 |
| 模型 guard 同时读取 AppKit 展示态 | 防止 Sheet/NSPanel 放行原始事件后菜单再次执行底层动作 |

## 风险与边界

- 普通常驻搜索框不全部禁用应用快捷键；只由现有非 app 编辑键走系统。
- 本轮不复制 cmux 为浏览器、多行输入和 IME 建立的复杂专用路由。

## 参考指针

- `apps/desktop-macos/Sources/AcroApp.swift:34-56`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:230-292`
- `apps/desktop-macos/Sources/CommandPalette.swift:239-242`
- `/Users/harry/project/acro/.tmp/cmux/Sources/AppDelegate.swift:13051-13351`
- `/Users/harry/project/acro/.tmp/cmux/Sources/App/ShortcutRoutingSupport.swift:335-375`

## 最终复核

- 命令面板条目先同步执行 `onDismiss`，再调用条目 action；展示态先恢复 normal，不会被模型 guard 误挡。
- 菜单、工作区数字、标签数字和 daemon restart 四类通知入口全部进入同一展示态 guard。
- 最终只读审查未发现 P0/P1/P2 correctness 问题。
