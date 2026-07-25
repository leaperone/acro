# 执行进度：compact-sidebar-uiux

- 任务 ID：`compact-sidebar-uiux-2026-07-26_02-19-59`
- 创建时间：`2026-07-26_02-19-59`
- 当前状态：`in_progress`

## 已完成

- 确认用户目标为 Compact 左侧栏，仓库中无 `Impact Mode`。
- 检查 Git 状态、已有 worktree、三态真源、全部入口、Compact 投影与现有测试。
- 对照已有 Wide 侧边栏和 MUXY 参考实现，收敛为单文件最小修改。
- 创建 `fix/compact-sidebar-uiux` 隔离 worktree，项目基线检查通过。
- 恢复调研中被误触的 `one.leaper.acro.helper` LaunchAgent，`ping` 返回新 PID，终端 daemon 和会话未受影响。
- Compact 选中项改为最小无动画滚动，并恢复系统滚动指示。
- 后续 Workspace 分组增加短分隔线；“新建工作区”复用 Wide 的明确图标。
- 服务器连接状态改为实心 / 环形内点 / 空心，不再只依赖颜色。
- 服务器和 Workspace 补充 VoiceOver 选中语义，Workspace 朗读包含分组上下文。
- Wide / Compact 共用底部图标按钮现在至少 32×32，并有轻量按压反馈。
- 完整 Swift 测试和桌面端构建通过。
- preflight 本地构建、旧 `origin/main` 合并探测和代码审查通过；共享 footer 按压反馈已补充“减少动态效果”适配。
- 用户追加明确要求：发布新 Desktop Beta。
- 分支已 rebase 到当前 `main@2e51070`，无冲突。
- rebase 后重跑完整 Swift 测试、`pnpm check`、`pnpm build` 与 diff 检查，全部通过。

## 进行中

- 更新验证后 push、开 PR、preflight 合并，再触发并监督 Desktop Beta 发布。

## 修改文件

- `.planning/compact-sidebar-uiux-2026-07-26_02-19-59/task_plan.md`
- `.planning/compact-sidebar-uiux-2026-07-26_02-19-59/findings.md`
- `.planning/compact-sidebar-uiux-2026-07-26_02-19-59/progress.md`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 真实 Acro 窗口 | 窗口存在；Orca 无法获取 Acro 的 accessibility window，helper 也无 Accessibility / Screen Recording 权限 | blocked |
| `leaperone-dev-init --check` | 项目基线有效 | passed |
| `swift test --package-path apps/desktop-macos` | 当前 main 树上 75 项 XCTest + 7 项 Swift Testing 全部通过 | passed |
| `swift build --package-path apps/desktop-macos` | 增量构建通过 | passed |
| `git diff --check` | 无空白错误 | passed |
| `pnpm check` | protocol、runtime、mobile、cli 检查全部通过 | passed |
| `pnpm build` | CLI / Runtime 构建通过；只有既有 esbuild `import.meta` 警告 | passed |
| Base merge probe | 分支已成功 rebase 到当前 `main@2e51070` | passed |
| preflight 代码审查 | 无 critical/high；1 个 medium 减少动效问题已修复，1 个 planning low 状态已校正 | passed |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `origin/main` 刷新失败：GitHub DNS 无法解析 | 1 | 使用已核对 SHA 一致的本地 `main` 创建 worktree。 |
| 只读 UI 子任务误启 helper，旧 Unix socket 失效 | 1 | `launchctl kickstart -k gui/501/one.leaper.acro.helper`，再用 `ping` RPC 确认恢复。 |
| Swift 测试找不到 `GhosttyKit/ghostty.h` | 1 | 使用 `apps/desktop-macos/scripts/setup-ghostty.sh` 恢复忽略资源，重跑后全部通过。 |
| push / fetch 无法解析 `github.com` | 2 | 已完成所有可用本地预检；保留干净分支和 worktree，不伪造 PR / merge 状态。 |
