# 执行进度：tab-bar-insertion-reorder

- 任务 ID：`tab-bar-insertion-reorder-2026-07-26_15-46-20`
- 创建时间：`2026-07-26_15-46-20`
- 当前状态：`in_progress`

## 已完成

- 已确认状态层排序和持久化链路完整。
- 已对照 cmux 与 Orca 本地源码，确认最小改动应只修顶部标签落点。
- 已创建隔离分支和 worktree。
- 已移除整条标签栏的重叠 drop 接收器，并为每个标签增加左右半区插入落点。
- 已完成完整桌面测试、Release 打包和独立实例启动。
- 已完成只读 diff 复核并删除溢出滚动时会误判末尾的冗余 viewport 落点。
- 已关闭本轮临时启动的第二个 UI；本机恢复为一个 UI、一个 runtime、一个 daemon，终端会话未重启。

## 进行中

- Git 提交、PR、preflight 和清理。

## 修改文件

- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `.planning/tab-bar-insertion-reorder-2026-07-26_15-46-20/*`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 仓库基线校验 | 通过 | completed |
| 参考仓库 `git pull --ff-only` | GitHub DNS 失败 | blocked-external |
| `swift test --package-path apps/desktop-macos` | 82 tests passed（XCTest 75 + Swift Testing 7） | completed |
| `bash apps/desktop-macos/scripts/package-app.sh 0.0.8-beta.15 45` | Release 构建、ZIP、DMG 成功；仅既有编译警告 | completed |
| 独立启动最终 `Acro.app` | UI 启动成功，复用现有 runtime / daemon | completed |
| 真实鼠标拖拽 | Computer Use、Accessibility、Screen Recording 均不可用 | not-run |
| `git diff --check` | 通过 | completed |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `Could not resolve host: github.com` | 2 | 使用干净本地快照继续，只把刷新状态列为外部边界 |
