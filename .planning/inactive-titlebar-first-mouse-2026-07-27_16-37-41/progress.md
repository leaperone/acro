# 执行进度：inactive-titlebar-first-mouse

- 任务 ID：`inactive-titlebar-first-mouse-2026-07-27_16-37-41`
- 创建时间：`2026-07-27_16-37-41`
- 当前状态：`in_progress`

## 已完成

- 对照 Acro 与 cmux 的 first-mouse 设计，确认顶部交互与正文必须分区处理。
- 搜索标签、关闭、分屏、标签空白拖窗、侧栏拖窗和终端正文的真实命中路径。
- 创建并校验独立 worktree `fix/inactive-titlebar-first-mouse`。
- 在旧实现上确认三项 first-mouse 回归断言失败，并单独提交红测。
- 让 pane hosting view 只在现有标签栏 registry 命中时接受 first mouse。
- 让 Bonsplit 标签栏背景、空白拖窗区和 Acro 侧栏拖窗区接受第一次鼠标操作。
- 完整 Bonsplit 与 Acro 桌面测试通过，release 构建通过。
- 候选 Beta.30 热替换 UI/runtime，daemon PID 1151 保持不变。
- 真实双窗口验证：Finder 在前台时第一次点击 Acro 的非选中标签，Acro 同次点击完成激活和标签切换。
- 清理真实 UI 验收中新建的临时终端标签，用户原有会话未删除。
- PR #146 最终代码审查未发现 critical、high、medium 或 low 问题。
- 预检的 TypeScript check/build 与 `origin/main` 合并冲突探测通过。

## 进行中

- 等待 PR CI 完成后 squash merge，并发布正式 Beta.30。

## 修改文件

- `apps/desktop-macos/Vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `.planning/inactive-titlebar-first-mouse-2026-07-27_16-37-41/`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro / cmux 源码对照 | 确认共享区域 registry 是最小根修入口 | 通过 |
| Git 状态 | worktree 基于 `516d330`，仅本任务 planning 未跟踪 | 通过 |
| Bonsplit first-mouse 红测 | hosting view 与 drag zone 两项断言均失败 | 符合预期 |
| Acro first-mouse 红测 | `WindowDragNSView.acceptsFirstMouse` 断言失败 | 符合预期 |
| Bonsplit 针对性测试 | 2 项通过 | 通过 |
| Acro 针对性测试 | 标签点击/拖拽/分屏与原生拖窗 2 项通过 | 通过 |
| Bonsplit 完整测试 | `swift test`，零失败 | 通过 |
| Acro 桌面完整测试 | XCTest 86 项 + Swift Testing 60 项，零失败 | 通过 |
| Release 构建 | `swift build -c release` | 通过 |
| 候选包 | `0.0.8-beta.30` build 61，ad-hoc 打包成功 | 通过 |
| 真实 UI | 后台窗口首次点击标签直接切换；临时标签已清理 | 通过 |
| 会话保持 | daemon PID 1151 未重启，原有终端会话仍在 | 通过 |
| Root check | `pnpm check` | 通过 |
| Root build | `pnpm build` | 通过（仅既有 esbuild `import.meta` 警告） |
| Base merge probe | 与 `origin/main` 无冲突 | 通过 |
| 最终代码审查 | Critical / High / Medium / Low 均为 0 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 本地打包缺少 `ACRO_SIGN_IDENTITY` | 1 | 按脚本契约显式使用 `ACRO_SIGN_IDENTITY=-` 生成仅供本机验收的 ad-hoc 包 |
