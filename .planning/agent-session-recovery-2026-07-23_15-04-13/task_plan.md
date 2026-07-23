# 任务计划：agent-session-recovery

- 任务 ID：`agent-session-recovery-2026-07-23_15-04-13`
- 创建时间：`2026-07-23_15-04-13`

## 目标

让 Acro 管理自己启动的 Codex / Claude Code 会话：展示真实 Agent 状态和 provider session id；Runtime 或 daemon 重启后恢复原 Agent；手机端可创建、查看、接管和恢复 Agent。

## 范围

- `packages/protocol`：Session Agent 元数据、创建参数、恢复 RPC 和状态事件。
- `apps/runtime`：Provider hook、Agent 启动参数、同 Session ID 冷恢复、启动恢复门。
- `apps/mobile`：Codex / Claude 创建入口、状态展示和恢复入口。
- `apps/desktop-macos`：协议 codegen 后的兼容修正。
- `.planning/blueprint.md`：记录 Agent 管理边界。

## 非目标

- 不开发第二个手机项目、原生 Chat、通知、Cloud Relay 或网络穿透。
- 不识别普通终端里手动启动的任意 Agent。
- 不接管 Agent 内部 Git、工具审批或 provider 账号系统。

## 关键约束

- Mac mini 持有 PTY、provider 会话和恢复状态；手机只显示、输入和控制。
- Hook 只监听 loopback，使用随机 token，失败时不得阻塞 Agent。
- Claude 使用 Acro 追加 settings；Codex 绑定启动时的真实 `CODEX_HOME`，保留用户 hooks，只追加并信任 Acro 自己的精确 hook。
- provider session id 必须限制长度并拒绝参数注入字符；恢复必须使用直接 argv。
- 恢复前必须比对不可逆账号指纹；账号或组织变化时拒绝静默恢复。
- daemon 冷恢复必须复用原 Acro Session ID，避免 Workspace 布局丢引用。

## 修改路径

- `packages/protocol/src/models.ts`
- `packages/protocol/src/rpc.ts`
- `packages/protocol/scripts/codegen-swift.ts`
- `apps/runtime/src/agent.ts`
- `apps/runtime/src/paths.ts`
- `apps/runtime/src/daemon/daemon.ts`
- `apps/runtime/src/index.ts`
- `apps/mobile/App.tsx`
- `apps/desktop-macos/Sources/Generated/ProtocolModels.swift`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- 相关测试与蓝图

## 验证方式

- 协议、Runtime、Mobile 针对性单测和类型检查。
- Runtime 构建与 macOS Swift 测试。
- 假 provider 验证 hook 状态映射、直接 argv 和同 ID 恢复。
- 本机开发实例真实创建、daemon 重启、手机可见性按可用环境验证。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前审查和 Git 收尾准备
- [x] 修复合并后 CI 暴露的 attach / detach 串行竞态

## 决策

| 决策 | 理由 |
|---|---|
| Agent 元数据作为 Session 可选字段，由 daemon checkpoint 持久化 | 复用现有 Session 单一真源，避免第二套 registry 合并和双写 |
| 只管理 Acro 创建的 Agent | Provider hook 才能可靠关联状态；终端输出和标题不能作为恢复身份 |
| 冷恢复复用原 Session ID | Workspace 和布局都引用现有 ID，无需迁移 |
| 手机复用现有终端 | 现有快照、增量输出、输入和接管已覆盖交互闭环 |
| Codex Session 持久化实际 `CODEX_HOME` | 恢复必须继续使用创建会话时的账号和配置边界，不能复制或覆盖认证状态 |
| Session 只保存不可逆账号指纹 | 恢复要绑定账号和组织，但不能持久化邮箱、账号 ID、token 或 API key |
| Hook 初始化失败时降级为普通终端 | 状态增强失败不能拖垮 Runtime，也不能把不可恢复会话标成受管 |
| 自动恢复使用统一绝对截止时间 | Provider、身份、Hook trust 和 daemon revive 共用预算，避免 Runtime 启动被历史会话长期阻塞 |
| 预算内 daemon 请求使用可对账的非冻结超时 | revive 是同 ID 幂等操作；超时后由 daemon 回滚，不能把共享客户端置为 stalled |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `leaperone-dev-init` 脚本名误用为 `init.sh` | 1 | 改用实际的 `scripts/init-project.sh`，基线初始化成功 |
| Runtime E2E 首次在删除临时状态目录时出现 `ENOTEMPTY` | 1 | 确认无残留进程，清理本轮临时目录后重跑，完整 E2E 通过 |
