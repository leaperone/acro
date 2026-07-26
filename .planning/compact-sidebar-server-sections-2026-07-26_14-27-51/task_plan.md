# 任务计划：compact-sidebar-server-sections

- 任务 ID：`compact-sidebar-server-sections-2026-07-26_14-27-51`
- 创建时间：`2026-07-26_14-27-51`

## 目标

让 Compact 侧边栏在保持 64pt 宽度和全部服务器/Workspace 同时展开的前提下，清楚表达每个 Workspace 所属的服务器区域。

## 范围

- 将每台服务器渲染为独立的圆角分区容器。
- 服务器主题色只用于服务器容器和 Header，Workspace 改用中性色。
- 简化 Workspace 选中态，并提升短名称辨识度。
- 更新最小布局与身份测试。

## 非目标

- 不增加折叠、搜索、动画或新的侧边栏状态。
- 不修改 Runtime、Workspace 模型、协议、持久化或完整侧边栏。
- 不改主仓既有的 release skill 和清理 planning 改动。

## 关键约束

- Compact 总宽度保持 64pt，所有服务器及其 Workspace 始终同时展开。
- 颜色表达服务器归属，Workspace 不再各自随机着色。
- 高频切换保持即时，保留现有上下文菜单、会话角标和无障碍语义。
- 使用现有 SwiftUI 能力，不新增依赖或抽象。

## 修改路径

- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `.planning/compact-sidebar-server-sections-2026-07-26_14-27-51/`

## 验证方式

- `swift test --package-path apps/desktop-macos --filter CompactSidebarTests`
- `swift test --package-path apps/desktop-macos`
- `swift build --package-path apps/desktop-macos`
- `pnpm check`
- `pnpm build`
- `git diff --check`
- 真实 UI 权限不可用时记录验证边界，不重复尝试同一路径。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成 Git 收尾

## 决策

| 决策 | 理由 |
|---|---|
| 用服务器区域容器表达归属 | 当前随机色同时作用于服务器和 Workspace，视觉编码互相竞争。 |
| Workspace 使用中性图标，只保留单一 Accent 选中背景 | 降低噪声，并避免图标色、背景和左竖条叠加。 |
| 保持 64pt 和全展开 | 这是用户明确的操作密度边界。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| HTTPS 无法解析 `github.com` | 1 | 使用一次性 GitHub 官方 SSH 443 URL 映射刷新 `origin/main`，未修改 remote 配置。 |
