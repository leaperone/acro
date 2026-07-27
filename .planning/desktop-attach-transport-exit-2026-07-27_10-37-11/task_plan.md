# 任务计划：desktop-attach-transport-exit

- 任务 ID：`desktop-attach-transport-exit-2026-07-27_10-37-11`
- 创建时间：`2026-07-27_10-37-11`

## 目标

attach 传输进程退出时，不再把它当成远端终端结束。仍存活的终端保留标签、窗格、顺序和自定义名称，并自动重新建立 surface。

## 范围

- 区分本地 attach surface 退出与服务端 Session 结束。
- 仍存活时重建 surface；服务端快照确认结束时再由现有对账删除布局。
- 增加回归测试，证明传输退出不会删除活会话布局。

## 非目标

- 不改变 daemon、PTY 或协议。
- 不扩展标签改名入口、关闭确认或其他 UIUX 审计项。

## 关键约束

- 服务端 Session 状态是唯一真相源。
- 不重启 daemon，避免结束现有终端。
- 复用现有 `RuntimeConnection.sessions` 和布局对账，不新增状态系统。

## 修改路径

- `apps/desktop-macos/Sources/AcroTerminalView.swift`
- `apps/desktop-macos/Sources/Ghostty.swift`
- `apps/desktop-macos/Sources/SettingsView.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证方式

- 先运行新增针对性 Swift 测试。
- 运行 Desktop 全量测试与 debug/release 构建。
- 运行 `pnpm check`、`pnpm build`、`git diff --check`。
- 真实 UI 自动化不可用时只记录边界，不重复尝试。

## 验收标准

- [x] attach 退出且 Session 仍 alive 时，布局和自定义标题不变。
- [x] live Session 的 surface 会重新创建，而不是停留空白。
- [x] Session 已结束或服务器被移除时，不再重启 surface，现有对账正常清理布局。
- [x] 自动化验证通过，且没有重启 daemon。

## 未确认事项

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| surface 退出不直接调用 `closeTab` | 本地传输退出不能证明远端 Session 已结束 |
| 用现有 alive 快照决定是否重启 | 断线时会保留上一份快照，符合会话持久化边界 |
| Session 删除继续交给现有 reconcile | 避免第二套布局清理逻辑 |
| 用户递归配置先加载，Acro overlay 最后加载 | 保证关闭来源判别不会被 config-file 反向覆盖 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 初次搜索被 zsh 未匹配 glob 中断 | 1 | 去掉可空 glob 后重新搜索 |
