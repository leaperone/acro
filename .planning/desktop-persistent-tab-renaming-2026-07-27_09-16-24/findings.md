# 调研与结论：desktop-persistent-tab-renaming

- 任务 ID：`desktop-persistent-tab-renaming-2026-07-27_09-16-24`
- 创建时间：`2026-07-27_09-16-24`

## 需求事实

- Bonsplit 已有 `.rename`、`.clearName`、`hasCustomTitle` 和三语言菜单文案，Acro 当前 allowlist 未开放前两项。
- 当前标题只来自 OSC / cwd /「终端」，没有用户覆盖层。
- Workspace 布局已经按 server/workspace 隔离，并同步到本机快照和服务端 opaque layout JSON。

## 真实调用链

- Bonsplit context menu → `TerminalPaneController.didRequestTabContextAction`。
- `TerminalPaneController.persist` → `WorkbenchModel.applyTerminalPaneLayout` → dirty layout push → `workspace.setLayout`。
- Runtime layoutRev → `WorkspaceTerminalLayout` decode → controller update / restore。
- 标题显示调用方包括顶部标签、Sidebar、Command Palette 和 Inspector。

## 调研结论

- `customTitlesBySessionId` 应放在 `WorkspaceTerminalLayout` 顶层，跨 pane 操作无需搬运第二份状态。
- 旧 JSON 需要显式 `decodeIfPresent ?? [:]`；非 optional 默认值不能保证 synthesized Decodable 兼容。
- rename 只改 metadata，不能触发 controller restore。
- trim 后空字符串等同 clear；removeTab / prune 清理对应 key。
- 旧客户端不保留未知布局字段，混合版本写回可能抹掉自定义标题。

## 技术决策

| 决策 | 证据 |
|---|---|
| 共享标题 resolver 读取 scoped layout | 防止顶部标签和其他 session 展示面名称不一致 |
| create/update 均传 hasCustomTitle | Bonsplit 依赖该状态决定是否显示“移除自定义名称” |
| 打包复制 app 本地化资源 | SwiftPM 可执行包当前没有自动嵌入 Acro 自身 Localizable.strings |

## 风险与边界

- 自定义标题不能按裸 sessionId 全局存储，否则不同服务器复用 ID 时会串名。
- 仅调用 `updateTab(title:)` 会被下一次 OSC/cwd 刷新覆盖。
- 旧客户端混合写入不属于本轮可安全解决的范围。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift:318`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:469`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:81,283,366,663`
- `.tmp/cmux/Sources/Workspace.swift:4179,10473,12407`
- `apps/desktop-macos/Vendor/Bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:1404`
