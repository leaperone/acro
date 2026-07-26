# 调研与结论：desktop-tab-action-fade

- 任务 ID：`desktop-tab-action-fade-2026-07-27_06-32-45`
- 创建时间：`2026-07-27_06-32-45`

## 需求事实

- PR #131 已让 Acro 使用 minimal，标签高度、拖拽、hover 显示时机和空白标题栏语义已与 cmux 一致。
- 当前剩余最确定的视觉差距是 hover 动作区渐隐参数。

## 真实调用链

- `TerminalPaneController.configuration` 构造 `BonsplitConfiguration.Appearance`。
- `TabBarView` 在 hover 后读取 `splitButtonBackdropEffect`，计算动作区背景、标签内容遮罩、分隔线渐隐和按钮 viewport。
- Acro 未传 effect，回退到 Bonsplit 默认；cmux 显式传生产调校值。

## 调研结论

- Acro 默认：fade 136、content fade 42、solid 2、无 separator fade、occlusion 1.0。
- cmux 生产：fade 99.75、content fade 28.875、solid 23.875、solid adjustment -80、separator fade 99.75、ramp 0.60、trailing 0.8625、occlusion 0.6875、mask true。
- 该差距独立于终端主题和产品能力，可以在 Acro 单一 appearance 配置点根修。

## 技术决策

| 决策 | 证据 |
|---|---|
| 逐字段锁定 cmux 生产 effect | 防止未来 vendor 默认值变化让 Acro 视觉回退。 |

## 风险与边界

- 真实视觉自动操作工具仍不可用，本轮用宿主配置测试、既有 Bonsplit 几何测试和热替换人工验收闭环。
- `chromeColors` 仍未跟随终端主题，作为后续独立根修保留。

## 参考指针

- `apps/desktop-macos/Sources/TerminalPaneController.swift:273-301`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift:427-468`
- `/Users/harry/project/acro/.tmp/cmux/Sources/BonsplitTabBarDebug.swift:114-135`
