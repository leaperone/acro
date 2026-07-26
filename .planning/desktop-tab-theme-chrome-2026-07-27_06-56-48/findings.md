# 调研与结论：desktop-tab-theme-chrome

- 任务 ID：`desktop-tab-theme-chrome-2026-07-27_06-56-48`
- 创建时间：`2026-07-27_06-56-48`

## 需求事实

- PR #133 已对齐 minimal 动作区渐隐，但 Acro 仍未设置 `chromeColors` 或 `usesSharedBackdrop`，因此标签栏继续使用系统灰色。
- cmux 的高质感选中态和 hover 依赖主题 chrome，而不是另改标签视图。

## 真实调用链

- `Ghostty.makeConfig()` 加载用户 XDG 配置、Acro 叠加配置和 recursive include 后 finalize。
- `Ghostty.reloadConfig()` 目前只调用 `ghostty_app_update_config`，没有把颜色变化通知给工作台。
- `WorkbenchModel.terminalPaneControllers` 持有全部工作区 controller，`synchronizeTerminalPaneControllers()` 是创建和更新入口。
- `TerminalPaneController.configuration` 是 Bonsplit appearance 的单一构造点。

## 调研结论

- 根因是 Ghostty 与 Bonsplit 外观状态断链，不是 Bonsplit 绘制能力缺失。
- `ghostty_config_get` 可以直接读取 finalized 配置的 `background` 与 `background-opacity`。
- 不透明主题可以让 tab bar、动作区和 pane chrome 透明，共享终端区域主题背景；半透明主题应使用预合成实色 chrome，避免双层透明。
- 红测证明 Acro 当前没有主题外观值对象、finalized config 解析入口或向全部 controller 分发的 API。

## 技术决策

| 决策 | 证据 |
|---|---|
| 不复制 cmux 的完整窗口玻璃系统 | Acro 当前只需要顶部标签与终端主题一致；复用 Ghostty 真源和 Bonsplit 原生 shared backdrop 即可。 |
| 不解析主题文件 | Ghostty 已完成条件主题和 include 解析，二次解析会产生分歧。 |

## 风险与边界

- 当前 UI 自动化目标不可用；代码与配置测试可证明状态链，真实视觉仍需热替换后由用户验收。
- Acro 尚未实现 cmux 的透明窗口/背景模糊系统，本轮不扩张到该能力。

## 参考指针

- `apps/desktop-macos/Sources/Ghostty.swift:73-121`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:180,513-542`
- `apps/desktop-macos/Sources/TerminalPaneController.swift:273-320`
- `.tmp/cmux/Sources/Workspace.swift:2699-2764,2830-2915`
