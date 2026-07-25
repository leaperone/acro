# 任务计划：compact-sidebar-uiux

- 任务 ID：`compact-sidebar-uiux-2026-07-26_02-19-59`
- 创建时间：`2026-07-26_02-19-59`

## 目标

改善 Compact 左侧栏的定位稳定性、信息层级、动作辨识度和无障碍选中语义，不改变 Wide / Compact / Hidden 三态契约；完成后发布新的 Acro Desktop Beta。

## 范围

- 取消选中 Workspace 时的强制居中动画，只在需要时保证目标可见。
- 让 Compact 中已有的 Workspace 分组边界可见。
- 复用已有 Workspace 图标，区分“新建工作区”与“连接服务器”。
- 为服务器和 Workspace 按钮补充 VoiceOver 选中语义。
- 让连接状态同时使用形状和颜色，并为 Workspace 补充分组上下文。
- 扩大侧边栏底部图标按钮的点击区，补充轻量按压反馈。
- 保留系统滚动指示，让长列表有位置和溢出反馈。
- 将改动合并到最新 `main`，发布下一个 `desktop-v0.0.8-beta.N`。
- 监督受信任 CI 完成签名、公证、GitHub Release 和 appcast 更新。

## 非目标

- 不改三态循环、快捷键、布局持久化或 Runtime 协议。
- 不增加图标自定义、新设置、新依赖或新抽象。
- 不手工打包、签名、公证、创建 Release 或改写 appcast 历史。

## 关键约束

- 保持 64pt 宽度和窗口红黄绿空间。
- Compact 仅负责快速导航；结构管理、会话树和破坏性操作仍属于 Wide。
- 只修改当前任务所需的 Compact 视图和 planning 文件。

## 修改路径

- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `.planning/compact-sidebar-uiux-2026-07-26_02-19-59/{task_plan,findings,progress}.md`

## 验证方式

- `swift test --package-path apps/desktop-macos --filter CompactSidebarTests`
- `swift test --package-path apps/desktop-macos --filter WorkbenchLayoutStateTests`
- `swift build --package-path apps/desktop-macos`
- `git diff --check`
- `pnpm check` / `pnpm build`
- PR CI 与 preflight 合并真相。
- `release.yml` repository dispatch 成功，自动批准 `desktop-release` 两道 environment。
- GitHub Release 资产、Beta appcast 顶部条目、签名与 delta 验证。
- 真实 UI 只在现有辅助功能和屏幕录制权限可用时验证；权限不可用时明确记录边界。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成 Git 收尾
- [x] 完成 Desktop Beta 发布与发布后验证

## 决策

| 决策 | 理由 |
|---|---|
| 修改 Compact 视图与已有 footer ButtonStyle | Compact 的信息问题在视图层；底部按钮命中区的根因在 Wide / Compact 共用样式，应修一处。 |
| 删除强制居中动画 | Workspace 可由按钮和键盘高频切换，强制居中会制造不必要的轨道跳动。 |
| 不增加新 UI 配置 | 这是默认交互质量问题，应直接给出好的默认值。 |
| Beta 版本只由 `release.yml` 产出 | 受信任管线是签名、公证、Release 和 appcast 的唯一入口。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 从 `origin/main` 创建 worktree 时 GitHub DNS 解析失败 | 1 | 初始检查已确认本地 `main` 与 `origin/main` 同一 SHA，改用本地 `main` 创建。 |
| 新 worktree 首次 Swift 测试缺少忽略的 `ghostty.h` | 1 | 运行仓库 `setup-ghostty.sh` 恢复固定版本资源，重跑通过。 |
| HTTPS Git 无法解析 `github.com` | 3 | 使用 GitHub 官方 `ssh.github.com:443` 一次性 URL 映射完成 push / fetch，未修改 remote 配置。 |
