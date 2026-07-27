# 调研与结论：desktop-persistent-tab-renaming

- 任务 ID：`desktop-persistent-tab-renaming-2026-07-27_09-16-24`
- 创建时间：`2026-07-27_09-16-24`

## 需求事实

- Bonsplit 已有 `.rename`、`.clearName` 和 `hasCustomTitle`；英文、日文菜单文案完整，简体中文缺少 rename / clear 两项，Acro 当前 allowlist 也未开放前两项。
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
- `tccd` 日志确认弹窗服务是 `kTCCServiceSystemPolicyAppData`；触发进程是 Acro 终端中的 bash/find，不是桌面代码主动扫描其他 App 数据。
- 主目录 Acro 使用 Developer ID 与 Team ID `5UAHRS482C`；worktree smoke 包使用同一 `one.leaper.acro.desktop`，但为无 Team ID 的 ad-hoc 签名。TCC 日志同时记录代码 requirement 不匹配，导致授权反复失效。
- 当前仅有一个 UI/runtime 实例；daemon PID 1151 自 7 月 23 日存活，映射的是已被后续打包覆盖的旧 inode。当前修复不能重启它，否则会结束现有终端。
- SwiftPM 生成的 Bonsplit accessor 只适合 SwiftPM 运行目录。把资源 bundle 放在 `Acro.app` 根目录会被 codesign 拒绝为 `unsealed contents present in the bundle root`；macOS App 必须把它放在 `Contents/Resources`，并让 Bonsplit 优先从 `Bundle.main.resourceURL` 解析。

## 技术决策

| 决策 | 证据 |
|---|---|
| 共享标题 resolver 读取 scoped layout | 防止顶部标签和其他 session 展示面名称不一致 |
| create/update 均传 hasCustomTitle | Bonsplit 依赖该状态决定是否显示“移除自定义名称” |
| 打包复制 app 本地化资源 | SwiftPM 可执行包当前没有自动嵌入 Acro 自身 Localizable.strings |
| ad-hoc 包改用独立 Bundle ID | ad-hoc designated requirement 等于易变 cdhash，不能与正式 Developer ID 包共用 TCC 主体 |
| Bonsplit bundle 复制到 `Contents/Resources`，Bonsplit 增加 App 资源解析 | 符合 macOS bundle 结构和代码签名规则，同时保留 SwiftPM 测试的 `.module` fallback |

## 风险与边界

- 自定义标题不能按裸 sessionId 全局存储，否则不同服务器复用 ID 时会串名。
- 仅调用 `updateTab(title:)` 会被下一次 OSC/cwd 刷新覆盖。
- 旧客户端混合写入不属于本轮可安全解决的范围。
- 09:08 启动稳定签名 Beta.21 后，`SystemPolicyAppData` 请求为 0。当前应保留已有授权；只有独立 ad-hoc ID 合入后仍复现，才针对正式 Bundle ID 有意识重置。
- daemon 的旧 inode 是热替换模型的已知结果，不是当前权限弹窗根因；TCC 责任链按 Acro bundle 归因。重启 daemon 会结束 9 个终端，本轮禁止执行。

## 参考指针

- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift:318`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:469`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:81,283,366,663`
- `.tmp/cmux/Sources/Workspace.swift:4179,10473,12407`
- `apps/desktop-macos/Vendor/Bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:1404`
