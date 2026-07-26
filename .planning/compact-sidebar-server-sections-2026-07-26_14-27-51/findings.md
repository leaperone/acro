# 调研与结论：compact-sidebar-server-sections

- 任务 ID：`compact-sidebar-server-sections-2026-07-26_14-27-51`
- 创建时间：`2026-07-26_14-27-51`

## 需求事实

- 用户要求所有服务器及其 Workspace 同时铺开，不接受折叠换空间。
- 当前服务器图标、随机色和普通间距不足以表达 Workspace 归属。
- 用户希望服务器拥有明显、完整的分区区域，同时继续保持 Compact 的极致密度。

## 真实调用链

- `WorkbenchView` 根据 `WorkbenchModel.leftSidebarPresentation` 渲染 `CompactSidebarView`。
- `CompactSidebarView` 遍历 `RuntimeHub.entries`，每个 entry 通过 `serverSection` 展示服务器 Header、分组和 Workspace。
- Workspace 选择仍调用 `model.activate` 与 `model.selectWorkspace`；本任务只调整渲染层。

## 调研结论

- 当前所有服务器已经同时展开，根因不是数据结构或折叠逻辑。
- 当前服务器和 Workspace 都从同一 8 色 palette 独立取色，颜色无法稳定表达父子归属。
- `serverSection` 只是普通 VStack，服务器之间只有空白；分区没有背景、边框或完整轮廓。
- Workspace 选中态同时使用图标着色、Accent 行背景和左侧竖条，视觉信号重复。
- 现有代码已经具备分组弱分隔线、连接状态形状、滚动到可见项、会话角标和 VoiceOver 选中 trait，应保留。

## 技术决策

| 决策 | 证据 |
|---|---|
| 每台服务器使用 56pt 圆角容器 | 64pt 总宽度可自然保留左右各 4pt，形成完整分区轮廓。 |
| palette 仅按 server id 取色 | 一个服务器一种主题色，Workspace 归属由共同容器表达。 |
| Workspace 名称使用最多两个字符 | 在不增加宽度和新图标体系的情况下，减少同首字符碰撞。 |

## 风险与边界

- 真实像素、深浅色对比度和 VoiceOver 实机朗读受本机 Screen Recording / Accessibility 权限限制。
- 容器不能增加嵌套卡片或额外标题行，否则会破坏 Compact 密度。
- 独立代码审查未发现 critical、high 或 medium 问题；确认 64pt、全展开、颜色归属、单一 Workspace Accent 和无障碍行为均保留。

## 参考指针

- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- 只读审查：`impact_sidebar_code`、`impact_sidebar_ui`
