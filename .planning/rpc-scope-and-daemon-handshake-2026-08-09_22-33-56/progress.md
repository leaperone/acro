# 执行进度：rpc-scope-and-daemon-handshake

- 任务 ID：`rpc-scope-and-daemon-handshake-2026-08-09_22-33-56`
- 创建时间：`2026-08-09_22-33-56`
- 当前状态：`ready_for_delivery`

## 已完成

- Exploring：核对 t3code 架构与 Acro 现状，确认三处缺口的真实调用链（见 `findings.md`）
- 用户确认 scope 落地层次为「后端机制 + 桌面端配对 UI」终局方案
- 创建 worktree `feat/rpc-scope-and-daemon-handshake`，基线校验通过
- 填写 planning 三文件

- S1a protocol：`RpcScope` + `METHOD_SCOPES` + `Device.scopes` + `device.share.scopes` + `E2eeAuthed.scopes`
- S1b runtime：`DeviceRegistry` scope 持久化，旧记录迁移为全 scope，local grant 恒为全 scope
- S1c runtime：`dispatch` 授权检查（先于参数校验与 in-flight 配额）、终端输入要求 control、`authed` 回传 scopes
- S1d desktop：配对 scope 勾选 UI（默认不勾 Computer Use / 管理）+ 设备列表回显权限
- S2 daemon 能力协商：扩展既有 `daemon.info` 返回 `methods`，`DaemonClient.negotiate()/supports()`，替换 index.ts 三处字符串匹配
- S5 事件注入 `workspaceId`：`workspaceIdForSession` + `withEventWorkspace` 统一包装两处广播
- S3 `docs/internals/` 三篇：`rpc.md`（含 scope 矩阵）、`connection.md`、`terminal-daemon.md`
- S4 连接状态机规格：写入 `connection.md`，标注桌面端已实现项与移动端待实现项
- S6 蓝图更新（scope 模型、事件 workspaceId、daemon 协商、移动端 libghostty-vt 终局、t3code 取材规则）；AGENTS.md 热替换 runbook 迁出到 docs/internals

## 进行中

- 交付收敛（commit / preflight）

## 修改文件

- `packages/protocol/src/{models,rpc,rpc.test}.ts`
- `apps/runtime/src/{devices,share,ws,index,workspaces}.ts` + 对应 `.test.ts`
- `apps/runtime/src/daemon/{daemon,client}.ts` + `client.test.ts`
- `apps/desktop-macos/Sources/SettingsView.swift`
- `apps/desktop-macos/Sources/Generated/ProtocolModels.swift`（codegen 产物）
- `docs/internals/{rpc,connection,terminal-daemon}.md`（新建）
- `AGENTS.md`（热替换 runbook 迁出，改为文档索引）
- `.planning/blueprint.md`
- `.planning/rpc-scope-and-daemon-handshake-2026-08-09_22-33-56/*`（planning 三文件）

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `pnpm --filter @acro/protocol test` | 15 pass / 0 fail | 通过 |
| `pnpm --filter @acro/runtime test` | 122 pass / 0 fail | 通过 |
| `pnpm check`（全仓 tsc --noEmit + 各包测试） | 全绿 | 通过 |
| `swift build`（desktop-macos） | Build complete | 通过 |
| `swift test`（desktop-macos） | 63 tests / 4 suites 全过 | 通过 |
| `grep "unknown method" apps/runtime/src/index.ts` | 无命中 | 通过 |
| 文档→源码相对链接可解析 | 全部有效 | 通过 |
| `pnpm build` | exit 0 | 通过 |
| `git merge-tree origin/main HEAD` | 无冲突 | 通过 |
| 端到端热替换验证 | — | 未执行（需本机重新打包与重启 dev 实例，属交付后验收） |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| worktree 内 `swift build` 报 `header 'ghostty.h' not found` | 1 | GhosttyKit.xcframework 与 `GhosttyKit/ghostty.h` 都不入 Git，从主 checkout 拷入 worktree（见 memory `desktop-worktree-build-artifacts`） |
| ws.test 夹具的 device 无 scopes，既有 dispatch 测试被 forbidden 拦截 | 1 | 夹具改为可指定 scope，默认全 scope；另加只读设备的拒绝矩阵测试 |
| 终端输入测试直接喂原始帧，夹具 session 无 `open` | 1 | 夹具补恒等 `open`，让测试走 `onMessage` 的真实解密后分支 |
| 自审发现 `withEventWorkspace` 会给 `session.focusChanged` 等未声明该字段的事件注入 workspaceId | 1 | 改为从 protocol 的 `events` 表推导 `WORKSPACE_SCOPED_EVENTS`，单一真源，新事件加字段即自动生效 |
| 自审发现协商期间连接断开仍会 `emit("up")`，让恢复流程在死连接上白跑 | 1 | 协商后比对 socket 身份，已被换掉则 reject，交给下一次重连；补回归测试 |
| 新增 client 测试触发真实重连循环导致测试进程不退出 | 1 | 测试内先 `close()` 再模拟 `onClose`，让重连不被安排 |
