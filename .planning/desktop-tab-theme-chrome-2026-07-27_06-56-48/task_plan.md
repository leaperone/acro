# 任务计划：desktop-tab-theme-chrome

- 任务 ID：`desktop-tab-theme-chrome-2026-07-27_06-56-48`
- 创建时间：`2026-07-27_06-56-48`

## 目标

让顶部 Bonsplit 标签栏使用 Ghostty 最终解析出的终端背景色，并在外观设置热重载后同步更新全部已缓存工作区，使选中态、hover、动作区和文字对比度与 cmux 的主题语义一致。

## 范围

- 从 finalized `ghostty_config_t` 读取背景色和透明度。
- 由 `WorkbenchModel` 把同一外观快照分发到全部 `TerminalPaneController`。
- 让终端区域提供共享主题背景；不透明主题使用 cmux 同款透明 tab chrome，半透明主题保留单层合成。
- 增加宿主级回归，覆盖初始配置、全部缓存 controller 更新和 reload 调用链。

## 非目标

- 不修改 vendored Bonsplit 或 GhosttyKit。
- 不新增主题设置、背景模糊、玻璃效果或侧边栏主题联动。
- 不实现标签右键菜单。

## 关键约束

- 主题真源必须是 Ghostty 已加载用户 XDG 配置、Acro 叠加配置和 recursive include 后的最终配置，不能另写主题解析器。
- 不透明主题才启用共享背景，避免半透明终端出现重复合成。
- reload 必须更新全部已存在 controller，不能只更新当前工作区。

## 修改路径

- `apps/desktop-macos/Sources/Ghostty.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SettingsView.swift`
- 对应 Desktop 测试。

## 验证方式

- 先增加失败测试，证明当前 controller 没有主题 chrome，且 model 没有更新全部 controller 的入口。
- 实现后运行针对性测试、全量 Desktop、`pnpm check`、`pnpm build` 和 release script tests。
- 合并后用 Developer ID 热替换本机 dev，保留 daemon 与现有会话。

## 验收标准

- 顶部标签栏背景和文字语义来自 Ghostty 最终背景色。
- 不透明主题的选中标签不再出现独立实色块，hover 使用轻量语义叠层。
- 更换 Acro 终端主题后，全部缓存工作区无需重建即可同步更新。
- 半透明主题不会叠加两次背景透明度。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| Ghostty finalized config 作为唯一主题真源 | Acro 已在单一 `makeConfig()` 中完成 XDG、叠加层和 include 解析，复用结果可避免解析漂移。 |
| 由 model 分发到 controller | model 已拥有全部缓存 controller；在这里更新可覆盖当前和后台工作区。 |
| 仅不透明主题启用 shared backdrop | Acro 尚未接管 Ghostty 半透明窗口背景；条件启用可避免重复合成。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无 |
