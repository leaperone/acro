# 执行进度：agent-session-recovery

- 任务 ID：`agent-session-recovery-2026-07-23_15-04-13`
- 创建时间：`2026-07-23_15-04-13`
- 当前状态：`complete`

## 已完成

- 核对主仓 dirty 状态和现有 worktree，保留全部无关修改。
- 从最新 `origin/main` 创建 `feat/agent-session-recovery` worktree。
- 完成协议、daemon、provider hook 和手机端三条只读调用链复核。
- 核对 Codex / Claude 当前 CLI 恢复参数及 Expo 57 文档边界。
- 完成 Session Agent 元数据、能力探测、状态事件、创建和恢复 RPC。
- 完成 daemon 直接 argv、Agent checkpoint、中断识别、同 Session ID revive 和恢复门。
- 完成 Claude 追加 settings、Codex 用户 hooks 合并、精确 trust、实际 `CODEX_HOME` 绑定和 hook fail-open。
- 完成 Codex / Claude 不可逆账号指纹；账号或组织切换后拒绝自动和手动 resume。
- Agent 自动恢复按 provider/home 分组，最多四组并发并受统一恢复预算约束。
- 统一恢复 deadline 已贯穿 Provider 探测、账号身份、Codex trust 和 daemon revive；预算超时不会冻结共享 DaemonClient。
- revive 过期会撤销新 PTY、恢复旧 dead metadata；磁盘回滚失败时不会保留新的 managed 档案。
- 完成手机 Workspace 分组、具体 Session cwd 启动 Agent、状态与恢复入口、空 Workspace、刷新和 attach 错误反馈。
- 完成 Swift codegen 和桌面兼容更新。

## 进行中

- 无代码实现或验证事项；等待 Git、PR、preflight、合并和清理。

## 修改文件

- `packages/protocol`：Agent 模型、RPC、事件、Swift codegen 与测试。
- `apps/runtime`：Agent hook/启动、daemon 持久化与恢复、Runtime 恢复门。
- `apps/mobile/App.tsx`：手机端 Agent 创建、状态、恢复和错误反馈。
- `apps/desktop-macos`、`apps/cli`：协议兼容。
- `.planning/blueprint.md` 与本任务三文件。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 既有 `@acro/mobile check` | 5 项通过（修改前基线） | 通过 |
| 既有 `@acro/runtime test` | 101 项通过（修改前基线） | 通过 |
| 既有 `@acro/protocol test` | 11 项通过（修改前基线） | 通过 |
| `pnpm check` | 全部 workspace 通过；Mobile 5 项、CLI 10 项 | 通过 |
| `pnpm build` | CLI 与 Runtime bundle 构建通过 | 通过 |
| `pnpm --filter @acro/runtime test` | 109 项通过 | 通过 |
| `pnpm --filter @acro/protocol test` | 13 项通过 | 通过 |
| `pnpm --filter @acro/runtime e2e` | 配对、Workspace、会话、断线重连、Runtime 重启全部通过 | 通过 |
| `swift package clean && swift test --package-path apps/desktop-macos` | 57 项 XCTest + 3 项 Swift Testing 通过 | 通过 |
| Expo `export --platform all` | iOS 与 Android bundle 均成功 | 通过 |
| 隔离 Codex hook / 身份 smoke | 保留用户 hook、精确信任、实际 `CODEX_HOME` 绑定；切换账号指纹后拒绝恢复 | 通过 |
| Hook 初始化失败 smoke | Runtime 继续工作，受管 Agent capability 关闭 | 通过 |
| daemon 恢复 smoke | 正常退出不误恢复；失败 revive 保留旧身份；成功 revive 同 ID | 通过 |
| 自动恢复 deadline / daemon timeout 回归 | 过期请求不发包；预算超时不冻结共享客户端；revive 在 daemon 内 fail-closed 回滚 | 通过 |
| 应用内浏览器 | 没有可用目标，未做真实 UI 验证 | 未验证 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `leaperone-dev-init` 入口名不存在 | 1 | 使用 `init-project.sh` 成功完成初始化 |
| daemon smoke 首次使用了错误测试环境变量 | 1 | 精确停止本轮临时 daemon，改用 `ACRO_DAEMON_TESTING=1` 后通过 |
| 身份 smoke 首次比较了 macOS `/var` 的非规范路径 | 1 | 改为比较 `realpath` 后通过，生产代码持久化规范化路径 |
| Runtime E2E 首次清理临时状态目录时报 `ENOTEMPTY` | 1 | 确认测试 daemon 已退出，清理该次临时目录后重跑，完整 E2E 通过 |
