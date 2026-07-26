# 执行进度：compact-sidebar-reorder

- 任务 ID：`compact-sidebar-reorder-2026-07-26_15-27-39`
- 创建时间：`2026-07-26_15-27-39`
- 当前状态：`complete`

## 已完成

- 已确认 Full/Compact 服务器排序差异、Workspace 重排 RPC 和 Command 提示调用链。
- 已确认本机 dev Beta.15 build 45 已重启，daemon PID 1151 保持不变。
- 已创建隔离 worktree并校验项目基线。
- 已实现本机优先服务器投影、远程服务器配置重排和本机重新配对置顶。
- 已接入 Compact 服务器/Workspace 原生拖拽、2pt 落点线和 `⌘1-9` 提示。
- 已修复 Full/Compact Workspace 重排切换服务器、读取旧分组顺序和 Compact 滚动跳回问题。
- 已使用两个仅进程内可见的自定义 UTType 隔离服务器、Workspace 和外部文本拖拽。
- 已完成独立最终审查，无 critical / high / medium 问题。
- 已打包并热替换最终 dev UI/runtime；daemon PID 1151 保持不变。

## 进行中

- 无。

## 修改文件

- `.planning/compact-sidebar-reorder-2026-07-26_15-27-39/`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/ServerDirectory.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`
- `apps/desktop-macos/Tests/ClientConfigPermissionsTests.swift`
- `apps/desktop-macos/Tests/SidebarDragReorderTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 只读调用链审查 | 修改范围和共享根因已确认 | 通过 |
| 本机 dev 重启 | UI/runtime 为 Beta.15 build 45，daemon PID 未变 | 通过 |
| Compact/Sidebar/ClientConfig 针对性测试 | 14 个测试通过 | 通过 |
| 完整 Swift 测试 | 77 个 XCTest 与 7 个 Swift Testing 测试通过 | 通过 |
| `swift build --package-path apps/desktop-macos` | 构建成功 | 通过 |
| `pnpm check` | workspace 类型检查与测试通过 | 通过 |
| `pnpm build` | CLI 与 Runtime 构建成功；仅有既有 `import.meta` 警告 | 通过 |
| `git diff --check` | 无空白错误 | 通过 |
| 独立代码审查 | 无 critical / high / medium 问题 | 通过 |
| 最终 dev 热替换 | UI/runtime 来自任务 worktree，daemon PID 1151 未变，codesign 通过 | 通过 |
| 自动真实 UI 验证 | Screen Recording / Accessibility 权限不可用，未重复尝试 | 未执行 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 自定义 UTType 测试缺少 import | 1 | 增加 `UniformTypeIdentifiers` import 后通过。 |
| LaunchServices 首次重启返回 `-609` | 1 | `open -n` 成功启动最终 dev app。 |
