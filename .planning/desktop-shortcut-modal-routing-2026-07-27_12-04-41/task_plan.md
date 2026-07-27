# 任务计划：desktop-shortcut-modal-routing

- 任务 ID：`desktop-shortcut-modal-routing-2026-07-27_12-04-41`
- 创建时间：`2026-07-27_12-04-41`

## 目标

命令面板、Alert、Sheet 和确认框打开时，全局快捷键不得穿透并执行底层工作台动作；普通工作台与常驻搜索框仍保留正常应用快捷键。

## 范围

- 在应用级 key monitor 的单一入口增加三态路由：执行应用动作、只吞事件、交给系统。
- 由 `WorkbenchModel` 暴露权威 presentation 状态，覆盖命令面板 pending/open 与全部工作台弹层。
- AppKit modal、sheet、NSPanel 作为非模型弹层兜底。
- 统一动作和数字快捷键入口增加 presentation 竞态保护。
- 增加真实 `NSEvent` 和模型行为回归测试。

## 非目标

- 不重做快捷键配置系统或菜单架构。
- 不把所有文本框都变成全局快捷键禁区。
- 不改变命令面板已有方向键、Return、Escape 和文本编辑行为。

## 关键约束

- 命令面板内的应用快捷键必须消费但不执行，不能简单回传给菜单或底层内容。
- 系统 modal/sheet/alert 必须收到原始事件，以保留默认确认、取消和窗口语义。
- presentation 状态必须在 FocusState 落到 field editor 前就生效。
- 普通状态的重复应用快捷键只消费一次，不重复执行。

## 修改路径

- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Sources/ShortcutSettings.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/ShortcutSettingsTests.swift`

## 验证方式

- 运行新增快捷键路由和模型 guard 测试。
- 运行 Desktop 全量测试与 release build。
- 运行 `pnpm check`、`pnpm build`、`git diff --check`。

## 验收标准

- [x] 普通终端中的首次应用快捷键执行，repeat 只消费不重复执行。
- [x] 命令面板打开或 pending-open 时，`⌘W`、`⌘N`、数字切换等不执行也不穿透。
- [x] 命令面板的普通输入、方向键、Return、Escape 和编辑等价键仍交给面板处理。
- [x] Alert、Sheet、confirmationDialog、NSPanel 和 modalWindow 中的快捷键交给系统。
- [x] 菜单/通知在 presentation 状态切换竞态下也不能绕过模型 guard。

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
| 三态 routing decision | 二态“吞或回传”无法表达命令面板需消费但不执行的语义 |
| 模型权威状态 + AppKit 兜底 | firstResponder 会漏掉命令面板刚显示但尚未聚焦的一帧 |
| 普通文本框不做 blanket bypass | 避免文件搜索框吞掉 Ctrl+Tab、Cmd+N 等应用导航 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Swift Package 测试中 `NSApp` 未初始化 | 1 | 改用 `NSApplication.shared` 后针对性与全量测试通过 |
