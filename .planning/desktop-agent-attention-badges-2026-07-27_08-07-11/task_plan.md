# 任务计划：desktop-agent-attention-badges

- 任务 ID：`desktop-agent-attention-badges-2026-07-27_08-07-11`
- 创建时间：`2026-07-27_08-07-11`

## 目标

让后台终端的 Agent 进入 waiting、done 或 error 时，顶部标签显示未读点；用户选中该标签后立即清除。

## 范围

- 将 Agent 状态纳入标签元数据快照和刷新触发。
- 在 `TerminalPaneController` 中维护本机未读状态和状态跃迁。
- Runtime 事件直接携带 Agent 快照，旧 daemon 保留全量刷新兼容。
- 增加可执行的 Swift 行为测试。

## 非目标

- 不新增视觉组件、文案、协议字段或服务端持久化。
- 不复制 cmux 的完整通知系统。
- 不处理“在右侧新建终端”或标签重命名。

## 关键约束

- 只有后台标签进入 `waiting` / `done` / `error` 才标记未读。
- 当前已选中标签不产生持续提示；选中后清除。
- 已读后重复的同一 `state + updatedAt` 事件不得重新出现；新 `updatedAt` 的同类事件可再次出现。
- Agent 或 session 消失时清理本地状态。
- 隐藏工作区的已选标签不算已读；只有当前 server/workspace 的可见标签才清除。
- 增量 Agent 事件必须抵抗在途旧快照覆盖。

## 修改路径

- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Tests/RuntimeConnectionEventTests.swift`
- `apps/runtime/src/daemon/daemon.ts`

## 验证方式

- 针对性 Desktop Swift Testing。
- Desktop 全量 Swift 测试、Bonsplit 测试、`pnpm check`、`pnpm build`。
- 打包后热替换本机 UI/runtime，保留 daemon 和现有 PTY。

## 验收标准

- 后台 Agent 等待、完成或报错时标签显示 Bonsplit 未读点。
- 选中标签后未读点立即清除，重复快照不回弹。
- 前台标签和 `starting` / `working` 不制造噪声。
- 标题和 cwd 的现有增量刷新不回归。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 复用 Bonsplit `showsNotificationBadge` | 现有视觉和可访问性语义已完整，不需要新组件 |
| 未读只存于桌面控制器 | 它是本机阅读状态，不是 Workspace 布局真源 |
| 首次看到后台 attention 状态也标未读 | 避免 App 启动后错过已经等待用户的 Agent |
| 用 `state + updatedAt` 识别事件 | 同一状态可能代表后续新的权限请求或停止事件 |
| 新 daemon 发送完整 Agent，旧 daemon 回退 refresh | 避免快速中间 attention 状态被合并快照吞掉，同时保持版本偏斜兼容 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| worktree 缺少忽略的 `GhosttyKit/ghostty.h` | 1 | 复用主 checkout 同版本预编译产物，不重复下载 |
| 隐藏工作区的已选标签被误判为已读 | 1 | 已增加工作区可见性条件和行为回归测试 |
