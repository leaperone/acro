# 调研与结论：rpc-scope-and-daemon-handshake

- 任务 ID：`rpc-scope-and-daemon-handshake-2026-08-09_22-33-56`
- 创建时间：`2026-08-09_22-33-56`

## 需求事实

- 来源：与 t3code（`.tmp/t3code`，MIT，上游 `pingdotgg/t3code`）的架构对照分析。
- 用户确认落地层次：scope 授权做**后端机制 + 桌面端配对 UI** 的终局方案，不做半成品。
- 用户要求六项全做，走标准开发流程。

## 真实调用链

### RPC 授权（现状：缺失）

`apps/runtime/src/ws.ts:311 onMessage`
→ 明文 `hello` 完成 E2EE 握手（`ServerHandshake.onHello`）
→ 首条加密消息必须是 `E2eeAuth`；`admissionMatchesToken` + `registry.auth(token)` 通过后 `conn.device` 落定，回 `authed`
→ 之后所有加密文本帧走 `dispatch(conn, req)`：`ws.ts:357`
→ `dispatch` 只做三件事：方法存在性、`method.params.safeParse`、并发 in-flight 上限
→ **直接调 handler，没有任何按方法的权限判断**

`index.ts` 里的 `requireActiveDevice(conn)`（`index.ts:340`）只断言 `conn.device` 存在且连接未关闭，不是授权检查。

后果：任一已配对 token 可调用全部方法，包括 `computer.click` / `computer.type` / `computer.key` / `computer.capture`（整机键鼠 + 录屏）、`fs.read` / `fs.search`、`git.diff`、`device.share` / `device.revoke`。

### daemon 版本探测（现状：比对错误文案）

`apps/runtime/src/daemon/client.ts:69 tryConnect` → 连上即 `emit("up")`，**无握手**，随后直接 `request(method)`。

三处隐式版本判断：
- `index.ts:304` `message === "unknown method session.createOwned"` → 改写为"daemon is outdated"提示
- `index.ts:504` `message === "unknown method session.cwd"` → 降级返回 `{ cwd: null }`
- `index.ts:576` `message === "unknown method session.cwd"` → 抛"daemon is outdated"

daemon 是 detached 进程、活过 runtime 重启（CLAUDE.md 热替换流程的前提），所以新 runtime + 旧 daemon 是**常态而非边缘情况**。

### 事件广播

`index.ts:937 emitRuntimeEvent` 与 `index.ts:966`（daemon 事件转发）都调用 `gateway.broadcastEvent`
→ `ws.ts:440`：遍历全部 `conns`，凡 `conn.device` 存在即发送，无任何过滤。

`Session`（`models.ts:147`）**没有 `workspaceId` 字段**；归属关系存在 `Workspace.sessionIds`（`models.ts:13`）。因此事件注入 workspaceId 需 runtime 反查 `workspaces`，daemon 无需改动。

### 设备模型

`models.ts:3 Device` = `{ id, name, createdAt, lastSeenAt }`，无权限字段。
`devices.ts:7 StoredDevice` 额外持 `tokenHash` + `local`，`publicView` 剥离。

**关键先例**：`local` 字段的 legacy 迁移（`devices.ts:25 legacyDeviceIds` + `devices.ts:127 migrateLegacyLocalGrants`）——旧记录缺字段时按 `Object.hasOwn` 识别并迁移。`scopes` 可直接沿用这一模式。

## 调研结论

- Acro 与 t3code 定位不同：t3code 编排 agent 会话（故有事件溯源、provider driver、checkpoint/VCS）；Acro 蓝图明确"不解析终端输出、不编排 Agent、不管 Git"。**t3code 过半架构不应移植**。
- 真正可迁移的是连接层纪律与边界约定，两个项目在这里面对同一组问题。
- t3code `RPC_REQUIRED_SCOPE` 按方法映射 scope、`authorizeEffect`/`authorizeStream` 分别拦截 unary 与 stream，其文档原句"Holding a valid socket is not authorization to call everything on it"正是 Acro 缺的那条不变式。
- t3code 靠全 TS 把连接策略收进 `packages/client-runtime` 供 web/mobile 共用；Acro 桌面端是 Swift（为 libghostty，选择正确），**代码不可能共享，只能共享规格 + 测试用例**。
- Swift 端 `RuntimeConnection.swift` 已有退避阶梯 `[0.5, 1, 2, 3, 5, 8]`（`:252`）、15 秒探针 timer（`:378`）、`reconnectAttempt` 计数（`:195`），策略已相当完整，规格文档应基于现状书写并标注 mobile 待实现项。
- t3code 连接规格中 Acro 尚未覆盖的点：离线时不消耗重试次数、连接稳定 N 秒后重置退避、建连中忽略普通前台激活、已连接时前台激活走 probe 而非重连、传输失败与业务失败分流、连接状态与数据同步状态分离为两个维度。

## 技术决策

| 决策 | 证据 |
|---|---|
| scope 分四档而非 RBAC | `rpc.ts:57` 方法表已按 `device.` / `workspace.` / `session.` / `browser.` / `simulator.` / `computer.` / `fs.` / `git.` / `ports.` 前缀天然分组；风险质变点只有 Computer Use 与设备管理两处 |
| 旧设备迁移为全 scope | `devices.ts:127 migrateLegacyLocalGrants` 提供同构先例，且不破坏用户现有配对 |
| daemon 握手复用 `daemon.info` 而非版本号常量 | daemon 与 runtime 独立升级，能力列表比单一版本号更能表达"哪些方法可用"；`client.ts` 在每次 `emit("up")` 之前重做握手，覆盖 daemon 重启 |
| 事件 workspaceId 由 runtime 注入 | `Session` 无归属字段，映射只在 runtime 的 `workspaces` 中；daemon 不感知 workspace 概念，不应为此改动 |
| docs 分 internals / operations 受众 | t3code `docs/` 按 user / internals / operations 分层，每篇用相对链接指向源码，文档随代码 review；Acro 现状是知识散落在 207 行 blueprint + 40 个 planning 目录 |

## 风险与边界

- **锁死自己**：scope 检查若把桌面端自身依赖的方法误判为高权限，会导致本机 dev 实例连不上。缓解：本机 grant（`local: true`）迁移为全 scope，且验收时先验旧设备可用再验新设备受限。
- **版本偏斜**：新 runtime 的 `authed` 回传 `scopes`，旧 Swift 客户端会忽略未知字段（JSON 解码需确认非严格模式）——需在实现时核对 Swift 端解码策略。
- **daemon 握手时序**：`client.ts` 在 `emit("up")` 之后、`restoreDaemonState()` 执行前必须完成握手，否则恢复流程读到空能力集会误判为旧 daemon。
- **事件字段新增**：旧 Swift 客户端对 events payload 的解码若为严格模式，新增 `workspaceId` 会导致解析失败——同上需核对。
- **preflight 领域检查**：改动横跨 protocol / runtime / Swift / docs，需确认 codegen 产物同步更新。

## 参考指针

- t3code 授权模型：`.tmp/t3code/docs/internals/overview.md`（"The RPC boundary" 节）、`.tmp/t3code/apps/server/src/ws.ts`
- t3code 连接状态机：`.tmp/t3code/docs/internals/connection-runtime.md`（"Connection State" / "Wakeups" 两节）
- t3code 文档分层：`.tmp/t3code/docs/internals/workspace-layout.md`
- t3code 终端 ABI 边界：`.tmp/t3code/docs/architecture/terminal-renderers.md`
- Acro 蓝图：`.planning/blueprint.md`（「通信与安全」节已承诺 per-RPC 检查）
- Acro 热替换 runbook 现址：仓库根 `AGENTS.md`「本机 dev 实例热替换」节
