# 任务计划：desktop-terminal-loading-state

- 任务 ID：`desktop-terminal-loading-state-2026-07-27_12-37-51`
- 创建时间：`2026-07-27_12-37-51`

## 目标

终端布局恢复、Runtime 首次快照、重连和新建分屏期间显示真实加载状态；只有服务端快照已经确认 session 不再存活时，才显示“终端已结束”。

## 范围

- 为终端标签内容建立加载、运行、结束三态判定。
- 新建终端 RPC 发出前立即创建 Bonsplit loading placeholder，并保留到权威快照出现 alive session。
- 用户关闭 pending placeholder 后，把远端删除意图交给 Runtime 连接；失败时保留并在后续快照自动重试。
- 空窗格在新建终端 RPC 期间显示创建中，而不是已结束。
- 复用 Runtime 的 `snapshotLoaded` 和 Session `alive` 作为权威事实。
- 增加纯状态判定与现有交互路径回归测试。

## 非目标

- 不修改 Runtime 协议、daemon 会话生命周期或 attach 重试策略。
- 不重做 Bonsplit 布局恢复和终端创建流程。
- 不改变服务端确认 session 已结束后的清理语义。

## 关键约束

- `snapshotLoaded == false` 代表未知，不能解释为 session 已结束。
- 标签尚未映射 session ID 时代表创建中的占位态。
- 已加载快照中缺失或 `alive == false` 的 session 才是结束态。

## 修改路径

- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Localization/{en,ja,zh-Hans}.lproj/Localizable.strings`

## 验证方式

- 运行新增终端内容状态测试。
- 运行 Desktop 全量测试与 release build。
- 运行 `pnpm check`、`pnpm build`、`git diff --check`。

## 验收标准

- [x] 恢复布局但快照未加载时显示“正在连接终端…”。
- [x] 新建分屏的空窗格显示“正在创建终端…”。
- [x] 快照中的 alive session 渲染真实终端。
- [x] 快照确认 session 缺失或死亡后才显示“终端已结束”。
- [x] Runtime 首次连接时显示连接中，而不是配对/未配置错误提示。
- [x] 创建 RPC 返回后关闭标签会删除远端 session；删除失败不会复活，并会在后续快照自动重试。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 使用 Runtime 快照加载状态区分未知与结束 | 服务端是会话状态唯一真源，客户端不能把空数组猜成死亡 |
| 空窗格显示创建中 | 分屏创建 RPC 完成前没有 tab/session 映射，这是正常过渡态 |
| 复用 `Bonsplit.Tab.isLoading` | 现有 tab 模型和 UI 已支持 spinner，不新增平行状态组件 |
| 新文案覆盖 en/ja/zh-Hans | 桌面包当前支持三种语言，键集合必须一致 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
| 从仓库根运行 `swift test` 找不到 `Package.swift` | 1 | 改到 `apps/desktop-macos` 后通过 |
