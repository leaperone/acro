# 调研与结论：agent-session-recovery

- 任务 ID：`agent-session-recovery-2026-07-23_15-04-13`
- 创建时间：`2026-07-23_15-04-13`

## 需求事实

- Acro 已有持久 PTY、E2EE 配对、断线重连、手机终端和跨设备接管。
- 当前 Session 没有 Agent 元数据，daemon 冷启动只把旧活会话标死。
- Orca 的温恢复是重新 attach 原 PTY；冷恢复是用 provider session id 执行原生命令。
- Codex 官方支持 `codex resume <SESSION_ID>`；Claude Code 支持 `claude --resume <SESSION_ID>`。

## 真实调用链

- `session.create` → Runtime 生成 Session ID / 关联 Workspace → daemon `session.createOwned` → node-pty → `meta.json` checkpoint。
- Runtime 重启时 daemon 与 PTY 仍存活，客户端重新 `session.attach` 获取 snapshot + seq。
- daemon 重启时 `loadDeadSessions()` 把 checkpoint 中 `alive=true` 改为 dead；Runtime 随后创建空终端，原 Agent 没有恢复。
- 手机端当前只消费 `session.list`；终端页已有查看、输入、resize、focus claim 和显式接管。

## 调研结论

- 终端标题、输出解析和 transcript 扫描都不能稳定把 provider session 映射到 Acro Session。
- Claude 可用 `--settings` 加载 Acro hook，不改用户设置。
- Codex 没有独立 hooks 文件参数；绑定登录 shell 解析出的实际 `CODEX_HOME`，合并用户 hooks，并通过 app-server 的 `hooks/list` / `config/batchWrite` 只信任 Acro 精确 hash。
- Hook 每次读取固定 endpoint 文件，Runtime 重启后旧 PTY 也能上报到新端口。
- 手机端无需原生 Chat，恢复后直接进入现有终端即可。

## Orca 对照

- Orca 把 provider session id 作为恢复身份持久化；恢复命令使用直接 argv，例如 `codex resume <id>` 和 `claude --resume <id>`。
- Orca 区分温恢复与冷恢复：PTY 仍在时重新 attach；PTY 已消失时才使用 provider 原生 resume。
- Orca 手机端通过配对凭据和加密 WebSocket 连接桌面或 headless runtime；网络入口可以是 LAN、Tailscale、隧道或反向代理，手机不执行开发任务。
- Acro 原本已经具备持久 PTY、E2EE 配对、手机终端、断线重连和多设备接管；缺口是 Agent 元数据、状态 hook、冷恢复和手机 Agent 入口。

## 技术决策

| 决策 | 证据 |
|---|---|
| Session 增加可选 `agent` | 现有所有客户端都以 Session 为列表和 attach 真源 |
| daemon 记录 `interrupted` | 只有 checkpoint 原 `alive=true` 能区分 daemon 中断与正常退出 |
| Provider 恢复直接 argv | session id 来自外部 hook，不能进入 shell 字符串 |
| 状态事件只通知刷新 | 避免事件和 `session.list` 维护两份完整 Session 快照 |
| 恢复绑定不可逆账号指纹 | 同一 Home 可以切换账号；只绑定路径会把旧会话恢复到错误账号或组织 |

## 风险与边界

- 旧 daemon 不认识 Agent 内部 RPC；新 Runtime 必须把它视为明确版本边界。
- Codex 恢复依赖 Session 中持久化的原始 `CODEX_HOME`；该目录不可在恢复时静默替换。
- Codex 指纹使用 provider/workspace account id，API key 模式使用 key 的 SHA-256；Claude 指纹使用 account/org id。指纹不包含原始身份字段或凭据。
- 无法取得强账号身份时，Agent 仍可运行和上报状态，但明确标记为不可自动恢复。
- Hook 失败必须 fail-open；状态可能暂时陈旧，但不能影响 provider 工作。
- 自动恢复的统一 deadline 必须传入 Provider 探测、身份查询、Codex trust 和 daemon revive；只在循环入口检查预算仍会让单个调用越界。
- 预算型 daemon 超时不能复用普通请求的全局 stalled 语义。revive 超时后必须撤销新 PTY、恢复旧 dead metadata，并允许 Runtime 继续启动。
- revive 回滚必须先删除新 `meta.json` 再写回旧记录；旧记录写回失败时要 fail-closed，不能留下新的 managed 档案供下次 daemon 启动误恢复。
- 同组首个恢复因 Hook 不可用而降级后，剩余会话继续以普通终端原生恢复；这符合既定 fail-open 边界，并且不会重复 Codex trust 或冒充受管 Agent。
- 当前手机尚无独立分发和真机可安装验证，本轮只接入已有 app。
- 本机曾暴露过终端 alias 中的敏感凭据；交付时必须提醒用户轮换，但不得记录或复述凭据内容。

## 参考指针

- `packages/protocol/src/models.ts`
- `apps/runtime/src/daemon/daemon.ts`
- `apps/runtime/src/index.ts`
- `apps/mobile/App.tsx`
- `/Users/harry/project/acro/.tmp/orca/src/shared/agent-session-resume.ts`
- Codex manual：Hooks common input fields、`codex resume`

## 最终审查

- Agent Hook、协议/daemon 持久化和手机端三条独立复核均未发现剩余 Critical / High / Medium。
- 应用内浏览器没有可用目标，本轮未做真实 UI 验收；这不阻断代码交付。
