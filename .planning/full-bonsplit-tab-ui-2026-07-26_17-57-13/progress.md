# 执行进度：full-bonsplit-tab-ui

- 任务 ID：`full-bonsplit-tab-ui-2026-07-26_17-57-13`
- 创建时间：`2026-07-26_17-57-13`
- 当前状态：`completed`

## 已完成

- 已更新 cmux 与最新 Bonsplit 源码，并完成真实实现深查。
- 已完成 Acro 与 Bonsplit 差距矩阵和旧 full-bonsplit worktree 复核。
- 已获得用户对完整架构替换的明确授权。
- 已从最新 `main` 创建独立 worktree。
- 已用完整 Bonsplit 替换 Acro 自研标签栏、分屏渲染和 pane/tab drop 链。
- 已建立按 server/workspace 隔离的 controller registry，并让快捷键、菜单、侧边栏和鼠标汇合到 Bonsplit。
- 已保留三态侧栏红绿灯 inset、终端 surface cache、占用蒙版、文件拖放、布局回写和多端同步。
- 已删除 `PaneDropTargetLayer`、`PaneTabBar`、`PaneTabItem`、`TabInsertionDropZone` 与对应旧测试。

## 进行中

- 无。

## 修改文件

- `apps/desktop-macos/Vendor/bonsplit/**`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/AcroTerminalView.swift`
- `apps/desktop-macos/Sources/FocusLockOverlay.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/scripts/package-app.sh`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 项目基线 | 通过 | completed |
| cmux/Bonsplit 源码版本 | `f79e3d86` / `48643102` | completed |
| Acro Desktop tests | 78 XCTest + 16 Swift Testing，全部通过 | completed |
| Bonsplit tests | 202 项全部通过 | completed |
| pnpm check / build | 全部通过；runtime 保留既有 esbuild `import.meta` warning | completed |
| Release package | `0.0.8-beta.19` / build `50`，zip 与 dmg 生成成功 | completed |
| 本机热替换 | UI/runtime 已换到任务 build；daemon PID 1151 保持不变；8790 health 正常 | completed |
| 真实 UI 自动化 | Orca computer runtime 未运行，按项目规则只检查一次后跳过；未完成拖拽手势自动验收 | not_run |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| GitHub HTTPS DNS/连接失败 | 3 | 使用已认证 SSH 443；Bonsplit shallow checkout |
| 新 worktree 缺少 GhosttyKit 头文件 | 1 | 运行仓库 `setup-ghostty.sh` 下载并校验固定版本产物 |
| 首次最终热替换 `open` 返回 LaunchServices -600 | 1 | 确认旧 UI/runtime 已退出后重新启动成功，daemon 未受影响 |
| GitHub desktop-macos 首轮找不到 Bonsplit `Bundle.module` | 1 | 根因是 desktop 级 `.gitignore` 忽略所有 `Resources`；强制跟踪上游 en/ja 本地化资源后重跑干净 Swift 构建 |
