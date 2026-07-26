# 执行进度：terminal-tab-title-refresh

- 任务 ID：`terminal-tab-title-refresh-2026-07-27_03-59-16`
- 创建时间：`2026-07-27_03-59-16`
- 当前状态：`complete`

## 已完成

- 核对 title 增量事件、snapshotRevision、Workbench reconcile 和 controller metadata 调用链。
- 确认现有事件测试只验证数据对象，未验证已渲染标签。
- 新增真实 SwiftUI 宿主测试，修复前断言 `tmp → vim` 失败。
- 实现实际渲染 tabs 的元数据指纹、资源作用域 key、session 字典和 runtime identity guard，针对性测试通过。
- reviewer 第二轮复核通过，无 blocker。

## 进行中

- 无。

## 修改文件

- `.planning/terminal-tab-title-refresh-2026-07-27_03-59-16/*`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码调用链 | title 数据更新后没有 tab metadata 刷新入口 | 确认缺陷 |
| 修复前行为测试 | runtime=`vim`，tab 仍为 `tmp` | 按预期失败 |
| 修复后行为测试 | tab 立即更新为 `vim`，revision/controller 不变 | 通过 |
| Acro Desktop 全量测试 | 79 XCTest + 20 Swift Testing | 通过 |
| 标题刷新定向测试 | 当前 workspace、后台 workspace 切入、空 metadata key 切换 3/3 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | 通过，仅既有 `import.meta` 警告 | 通过 |

## 交付前收敛

- 最终 diff 只增加当前工作区标签元数据失效入口和对应行为测试。
- 标题变化不改变 controller identity、workspace layout 或 snapshotRevision。
- 未修改 Bonsplit、daemon 标题采集或全局布局对账逻辑。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 0 | 无 |
