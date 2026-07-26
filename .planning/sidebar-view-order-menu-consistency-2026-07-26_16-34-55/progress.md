# 执行进度：sidebar-view-order-menu-consistency

- 任务 ID：`sidebar-view-order-menu-consistency-2026-07-26_16-34-55`
- 创建时间：`2026-07-26_16-34-55`
- 当前状态：`ready_for_preflight`

## 已完成

- 已核对 Full/Compact 服务器、Workspace、快捷键和菜单真实调用链。
- 已创建独立 worktree，并确认服务器/Workspace 排序真相源无需变化。
- Full/Compact 已共用服务器与 Workspace 右键菜单组件。
- Full 已增加远程服务器拖拽；两种视图共用服务器 drop planner 和持久化入口。
- 菜单动作已改为显式 server/connection 路由，并在执行时重新读取最新实体。
- 断线 Runtime 写操作统一禁用，危险动作独立置底并复用现有确认流程。

## 进行中

- 等待提交、PR、preflight 合并与 Beta 发布。

## 修改文件

- `.planning/sidebar-view-order-menu-consistency-2026-07-26_16-34-55/`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/ServerDirectory.swift`
- `apps/desktop-macos/Tests/ClientConfigPermissionsTests.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `apps/desktop-macos/Tests/SidebarDragReorderTests.swift`
- `apps/desktop-macos/Tests/WorkbenchLayoutStateTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 只读调用链审计 | 顺序与快捷键已共享；菜单和服务器排序入口仍不一致 | 通过 |
| Swift tests | 80 XCTest + 7 Swift Testing，共 87 个通过 | 通过 |
| Swift build | Debug 与 release package build 通过 | 通过 |
| pnpm check | protocol/runtime/cli/mobile 全部通过 | 通过 |
| pnpm build | runtime/cli 构建通过；仅既有 import.meta warning | 通过 |
| dev 热替换 | build 48 UI/runtime 已启动，daemon PID 1151 保留 | 通过 |
| 真实 UI 自动化 | Orca runtime 未启动，Screen Recording 不可用；按规则停止重试 | 未执行 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| GitHub HTTPS DNS 解析失败 | 1 | 使用一次性 SSH 443 映射创建 worktree |
| 首次 Swift test 缺 GhosttyKit header | 1 | 运行仓库 `setup-ghostty.sh` 后通过 |
| 首次 dev package 使用 build 47 | 1 | 重新以 Beta.17 正确 build 48 打包并热替换 |
