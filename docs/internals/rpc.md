# RPC 与授权

> 面向维护者。协议的唯一真源是 [`packages/protocol/src/rpc.ts`][rpc]，本文只解释它为什么长这样。

客户端与 Runtime 之间只有一条 WebSocket。控制消息是 JSON 文本帧（[`rpc.ts`][rpc] 的
`RpcRequest` / `RpcResponse` / `RpcEvent`），终端与画面数据是二进制帧（[`frames.ts`][frames]）。
HTTP 只保留健康检查。

## 方法表是唯一真源

[`rpc.ts`][rpc] 的 `methods` 同时被三方消费：服务端据此校验入参、TypeScript 客户端据此推导类型、
Swift 端据此 codegen（`pnpm --filter @acro/protocol codegen:swift`）。禁止在任何客户端手工镜像协议类型。

## 授权：持有连接不等于可以调用一切

E2EE 握手 + token 认证只证明「这是一台已配对的设备」。它**不**证明这台设备有权调用某个方法。

授权分两层，都在 [`ws.ts`][ws]：

1. **认证**：首条加密消息必须是 `auth`；`admissionMatchesToken` 校验升级期提示与信道内 token 一致，
   `DeviceRegistry.auth` 换出设备身份。失败即断开连接，不返回错误响应。
2. **授权**：`dispatch` 在**参数校验之前**查 `METHOD_SCOPES`，设备缺少该 scope 时直接返回
   `forbidden`。放在参数校验之前有两个理由——未授权的方法不该泄露它对参数的偏好，也不该占用
   in-flight 配额。

`deviceHasScope` 是唯一判定点。`scopes` 为 null/空一律判为无权限：授权判断不接受含糊的输入。

### scope 档位

| scope | 含义 | 典型方法 |
|---|---|---|
| `read` | 浏览。文件、Git、端口、会话列表与画面订阅 | `fs.*`、`git.*`、`ports.list`、`*.list`、`session.attach` |
| `control` | 控制 Acro 管理的会话与表面 | `session.create` / `kill` / `resize`、`workspace.*`、`browser.*`、`simulator.boot`、`daemon.restart` |
| `computer` | Computer Use：键鼠注入、应用激活、录屏。作用于**整台 Mac**，不限于 Acro 的表面 | `computer.click` / `type` / `key` / `activate` / `capture` / `windows` |
| `admin` | 设备管理：分发与收回访问权 | `device.list` / `share` / `revoke` |

`computer` 与 `admin` 单独成档，因为它们是权限的质变点：前者等于整机控制，后者能再分发访问权。
`computer.controlOwner` 与 `computer.permissions` 只读状态，归 `read`。

### 终端输入

终端输入走 `FRAME_IN` 二进制帧，不经过方法表，但它是不折不扣的控制操作。
[`ws.ts`][ws] 的 `onMessage` 在转发前检查 `TERMINAL_INPUT_SCOPE`（= `control`）：
只读设备可以 attach 看画面，不能打字。

这与「输入所有权」是两条独立约束，顺序是先 scope 后 owner：
- scope 决定这台设备**有没有资格**输入；
- `inputGate` 决定这台设备**此刻是不是**该会话的占用者（见 `session.claimFocus`）。

### 授予与迁移

- 新配对默认 `DEFAULT_GRANT_SCOPES` = `read` + `control`。Computer Use 与设备管理必须由用户在
  桌面端配对界面显式勾选。
- 本机 grant（`local: true`）恒为全 scope，否则桌面端会把自己锁在外面。
- 升级前配对的设备（`devices.json` 中没有 `scopes` 字段）迁移为全 scope。静默降权会让用户
  正在用的设备突然报 `forbidden`，比暂时宽松更糟。迁移逻辑见 [`devices.ts`][devices] 的
  `normalizeScopes`。

客户端在 `authed` 消息里收到本连接的 scopes，用于隐藏无权使用的入口。**这只是 UI 提示**：
拒绝的唯一权威是服务端 dispatch 时的检查。

### 加一个方法时

`METHOD_SCOPES` 的类型是 `Record<MethodName, RpcScope>`，漏掉新方法会编译失败。
这是刻意的：新方法必须显式表态它需要什么权限，没有「默认档位」。

## 事件

服务端事件定义在 [`rpc.ts`][rpc] 的 `events`，带 `seq` 和 `boot`：`boot` 变了说明服务端重启过，
客户端必须全量重新同步；`seq` 用于同一 boot 内的断点续传（见 [connection.md](./connection.md)）。

`session.*` 事件带 `workspaceId`。daemon 只认 sessionId，归属关系只有 Runtime 知道，
所以由 [`index.ts`][index] 的 `withEventWorkspace` 在广播前反查注入。

**当前事件仍广播给全部已认证连接。** `workspaceId` 供客户端本地路由，
同时也是将来按订阅收敛推送时的过滤依据。在实测到弱网带宽问题之前，不引入订阅过滤。

## 相关

- [连接与重连](./connection.md)
- [终端 daemon](./terminal-daemon.md)

[rpc]: ../../packages/protocol/src/rpc.ts
[frames]: ../../packages/protocol/src/frames.ts
[ws]: ../../apps/runtime/src/ws.ts
[devices]: ../../apps/runtime/src/devices.ts
[index]: ../../apps/runtime/src/index.ts
