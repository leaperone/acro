# 任务计划：rpc-scope-and-daemon-handshake

- 任务 ID：`rpc-scope-and-daemon-handshake-2026-08-09_22-33-56`
- 创建时间：`2026-08-09_22-33-56`

## 目标

按 t3code 对照分析结论，补齐 Acro 在授权粒度、版本协商与架构文档三方面的缺口：

1. RPC 按方法授权（scope），关闭"持有有效 socket 即可调用全部方法"的安全缺口，兑现蓝图「通信与安全」已承诺的"服务端为每个控制 RPC 检查设备与操作类型"。
2. runtime↔daemon 显式能力协商，替换靠比对错误文案的隐式版本探测。
3. 把散落在 blueprint / CLAUDE.md / planning 里的架构与运维知识固化到 `docs/internals/`。

## 范围

- **S1 scope 授权（后端机制 + 桌面端配对 UI，终局）**
  - `packages/protocol`：`RpcScope` 枚举（`read` / `control` / `computer` / `admin`）、方法→scope 映射表、`Device.scopes` 字段、`device.share` 接受 `scopes` 参数。
  - `apps/runtime`：`DeviceRegistry` 持久化 scope 并迁移旧记录；`Gateway.dispatch` 在参数校验后、handler 调用前检查 scope；`E2eeAuthed` 回传本连接的 scopes。
  - `apps/desktop-macos`：配对新设备时可勾选授予的 scope；设备列表显示已授予 scope。
- **S2 daemon 能力协商**
  - 扩展既有 `daemon.info` 返回 `methods`（无需新增方法）。
  - `DaemonClient` 连接建立后握手一次，暴露 `supports(method)`；旧 daemon（任何握手失败）判定为 v0、能力集为空。
  - `index.ts` 三处 `message === "unknown method ..."` 改为查能力集。
- **S3 `docs/internals/` 三篇**：`connection.md`、`terminal-daemon.md`、`rpc.md`（含 scope 矩阵）。`terminal-daemon.md` 承接 CLAUDE.md 的热替换 runbook。
- **S4 连接状态机规格**：`docs/internals/connection.md` 内一节，写成 Swift / TS 两端共同规格 + 各端实现状态。
- **S5 事件加 `workspaceId`**：runtime 转发 daemon session 事件时注入所属 workspace；只加字段，不做订阅过滤。
- **S6 蓝图更新**：移动端终端 libghostty-vt 终局方向、scope 授权模型、docs/internals 入口。

## 非目标

- 不引入事件溯源引擎、provider driver registry、checkpoint/VCS 抽象或 Effect（t3code 为编排 agent 会话服务的架构，与 Acro 非目标冲突）。
- 不做事件订阅过滤（S5 只留字段口子，等实测到弱网带宽问题再做）。
- 不改移动端终端实现（xterm.js 保留，仅在蓝图记录终局方向）。
- 不改 E2EE 握手、配对码格式或传输层。
- 不引入 RBAC、角色继承或按 workspace / 项目粒度的资源级授权（本轮只到方法级）。

## 关键约束

- 已配对设备迁移为全 scope，不得让用户现有 iPhone / MacBook 失效。
- 新配对默认不含 `computer` 与 `admin`，需用户显式勾选。
- 协议唯一真源是 `packages/protocol` 的 zod schema，Swift 类型走 codegen，禁止手工镜像。
- 版本偏斜兼容：新客户端连旧 runtime、新 runtime 连旧 daemon 都必须可用（新增字段 nullable + default）。
- daemon 活过 runtime 重启是常态，能力协商必须在每次 daemon 连接建立后重做。
- 事件 payload 新增字段对旧客户端必须是可忽略的。

## 修改路径

- `packages/protocol/src/models.ts`：`Device.scopes`
- `packages/protocol/src/rpc.ts`：`RpcScope`、`METHOD_SCOPES`、`device.share` params、`E2eeAuthed.scopes`、events 加 `workspaceId`
- `apps/runtime/src/devices.ts`：scope 持久化与旧记录迁移
- `apps/runtime/src/ws.ts`：`dispatch` scope 检查、`authed` 回传 scopes
- `apps/runtime/src/share.ts`：`createShareOffer` 透传 scopes
- `apps/runtime/src/index.ts`：三处字符串匹配改能力查询、session 事件注入 workspaceId
- `apps/runtime/src/daemon/client.ts`：握手与 `supports()`
- `apps/runtime/src/daemon/daemon.ts`：`daemon.info` 报告 `methods`
- `apps/desktop-macos/Sources/`：配对 scope 勾选 UI、设备列表 scope 展示
- `docs/internals/{connection,terminal-daemon,rpc}.md`（新建）
- `AGENTS.md`：docs/internals 引用、热替换章节迁出后的指针
- `.planning/blueprint.md`：scope 模型、移动端终端终局、文档入口

## 验证方式

- `pnpm -r test`（runtime + protocol vitest）
- 新增单测：scope 拒绝/放行矩阵、旧设备迁移、daemon 握手降级到 v0、事件 workspaceId 注入
- `swift build` + `swift test`（desktop-macos）
- 端到端：本机 dev 实例热替换流程（见 `docs/internals/terminal-daemon.md`），验证已配对设备仍可用、新配对设备缺 computer scope 时 `computer.click` 被拒
- `preflight`

## 验收标准

- [x] 未授予 `computer` scope 的设备调用 `computer.click` / `computer.capture` 返回 `forbidden`，授予后放行
- [x] 未授予 `admin` 的设备调用 `device.share` / `device.revoke` 被拒
- [x] 旧 `devices.json`（无 scopes 字段）加载后设备拥有全部 scope，现有连接不受影响
- [x] `index.ts` 中不再有 `message === "unknown method ..."` 形式的版本判断
- [x] 旧 daemon（`daemon.info` 不报告 `methods`）下 runtime 仍给出与现状一致的"daemon is outdated"提示，不崩溃
- [x] `session.created` / `session.exit` / `session.removed` / `session.title` 事件携带 `workspaceId`（无归属时为 null）
- [x] `docs/internals/` 三篇存在，源码引用为相对链接且路径有效
- [x] 桌面端配对新设备时可勾选 scope，默认不勾 Computer Use 与管理
- [x] 蓝图记录 scope 模型与移动端 libghostty-vt 终局方向

## 未确认事项

- 无（scope 落地层次已由用户确认为「后端机制 + 桌面端配对 UI」终局方案）

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| scope 分四档 `read` / `control` / `computer` / `admin`，不做 RBAC | 方法表已有天然前缀分组；Computer Use（键鼠+录屏）和设备管理是两类质变权限，单独成档即可覆盖真实风险，更细粒度无需求支撑 |
| 已配对设备迁移为全 scope | 不破坏用户现有配对；沿用 `devices.ts` 中 `local` 字段既有的 legacy 迁移模式 |
| 新配对默认排除 `computer` / `admin` | scope 的安全收益在于最小授权；Computer Use 等于整机控制，必须显式授予 |
| 能力协商复用既有 `daemon.info` 而非新增方法 | `daemon.info` 已存在且已带 `features` 字段，加 `methods` 是最小改动；握手任何失败一律落到空能力集，语义明确且不依赖错误文案 |
| S5 只加 `workspaceId` 字段，不做订阅过滤 | 当前 workspace/设备数量下过滤是过度设计；先留协议口子，实测弱网带宽问题再做 |
| 不引入 Effect / 事件溯源 / provider driver | t3code 这些机制服务于"编排 agent 会话"，与 Acro 非目标（不解析终端输出、不编排 Agent、不管 Git）冲突 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| | 1 | |
