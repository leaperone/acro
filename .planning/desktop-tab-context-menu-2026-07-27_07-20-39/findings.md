# 调研与结论：desktop-tab-context-menu

- 任务 ID：`desktop-tab-context-menu-2026-07-27_07-20-39`
- 创建时间：`2026-07-27_07-20-39`

## 需求事实

- Acro 当前显式 `allowsTabContextMenu: false`，因为 Bonsplit 默认菜单包含大量 Acro 未实现的动作。
- 用户需要的是 cmux 同款有效交互，不是把开关直接翻开。

## 真实调用链

- `TabContextMenuBuilder` 固定构建 rename、close、move、browser、pin、unread、zoom 等全部菜单。
- `BonsplitController.requestTabContextAction` 仅对 full-width 内建处理，其余交给 delegate。
- `TerminalPaneController` 已持有 tab/session 映射、相邻 pane 查询和布局持久化。
- `WorkbenchModel` 的单标签终止已实现 `session.remove` 失败时回退 `session.kill`，但没有批量确认入口。

## 调研结论

- 根因是 Bonsplit 缺少宿主动作可见性契约；直接打开菜单会产生大量无效项。
- 关闭左右/其他需要批量 Runtime 终止，不能调用多次单标签确认。
- 相邻 pane 移动、zoom 和 full-width 已有 Bonsplit 原生 API，可直接复用。
- `newTerminalToRight` 需要异步创建后的锚点重排；Acro 当前创建链只按当前选择插入，本轮不能诚实开放。
- 红测确认当前不存在宿主菜单白名单和批量会话终止状态；相邻窗格动作也尚未路由。
- 实现后 Bonsplit 默认 `nil` 菜单保持完整；Acro allowlist 会递归清除未支持动作、空子菜单和多余分隔线。
- 批量终止按目标顺序执行；单项 RPC 失败不会阻断后续项，成功项即时移除，最后最多 refresh 一次。
- 动态 Move destination 的 ID 可能与 `TabContextAction.rawValue` 重名；过滤器必须按菜单 selector 区分宿主动作与 destination，不能只解析字符串。
- `apps/desktop-macos/.gitignore` 忽略通用 `Resources` 目录；新增 `zh-Hans.lproj` 必须显式进入 Git 索引，否则干净 checkout 会回退英文。

## 技术决策

| 决策 | 证据 |
|---|---|
| 白名单在最终 NSMenu 上递归裁剪 | 不重写完整菜单；默认 nil 保持 cmux/Bonsplit 现有行为。 |
| 开放 full-width | 与 zoom 同属 Bonsplit controller 的瞬时视图状态，原生实现会先选择右键目标。 |
| 不为批量关闭新增对话框文案 | 现有“关闭终端”确认准确覆盖单个和多个目标，复用可避免重复产品语义。 |

## 风险与边界

- vendored Bonsplit 新增的是通用、默认关闭的宿主能力，需确保默认菜单快照完全不变。
- UI 自动化目标仍不可用，真实右键视觉需热替换后人工验收。

## 参考指针

- `Vendor/bonsplit/.../BonsplitConfiguration.swift:45-136`
- `Vendor/bonsplit/.../TabItemView.swift:1346-1584`
- `TerminalPaneController.swift:174-282`
- `WorkbenchModel.swift:794-1037`
