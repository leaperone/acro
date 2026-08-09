# 终端 daemon

> 面向维护者。

终端由独立的 daemon 进程持有：node-pty 驱动 PTY，服务端 headless 终端维护屏幕状态，checkpoint 落盘。
**Runtime 升级或崩溃不影响会话。** daemon 实现大量取用 orca（MIT）。

## 进程模型

一个运行中的 Acro 实例 = 三个进程：

| 进程 | 角色 | 生命周期 |
|---|---|---|
| UI（`AcroDesktop`） | SwiftUI 桌面客户端 | 随用户操作启停 |
| runtime（`runtime.cjs`） | RPC 网关、工作区、文件 / Git / 端口、浏览器与模拟器 | 随 UI 启停 |
| daemon（`daemon.cjs`） | 持有全部 PTY 与终端屏幕状态 | **detached，活过 UI / runtime 重启** |

daemon 有自己的 pgid，被 detached 拉起。它活过 runtime 重启是设计而非巧合：
只更新 UI + runtime 就能拿到新 UI 和新 RPC，正在跑的终端会话不受影响。

Runtime 通过 unix socket 连接 daemon（[`client.ts`][client]），断线自动重连并按需拉起 daemon。

## 能力协商

因为 daemon 活过 runtime 重启，**「新 runtime + 旧 daemon」是常态，不是边缘情况。**

协商走 [`daemon.ts`][daemon] 的 `daemon.info`，它返回 `{ boot, pid, features, methods }`。
[`client.ts`][client] 在每次连接建立后、宣告 `up` 之前握手一次，把 `methods` 存进能力集，
通过 `supports(method)` 暴露。

规则：

- **能力绑定到连接，不是进程。** 每次重连重新协商，断开即清空。
- **握手失败一律落到空能力集。** 旧 daemon 的响应没有 `methods`、超时、报错——都判定为
  「不支持任何需要显式声明的方法」。
- **调用方不解析错误文案。** 需要新方法时调 `supports()`，不支持就走 [`index.ts`][index] 的
  `requireDaemonMethod`，给出「daemon 过旧」的可操作提示。版本边界检查前置在建立任何状态之前，
  宁可早失败也不要留下半个会话。

加一个 daemon 方法时不需要额外注册：`daemon.info` 直接报告 `handlers` 的键。

## Agent 冷恢复

1. Provider hook 把 Codex / Claude 的 session id 和状态写入终端 Session checkpoint。
2. Runtime 重启但 daemon 存活时，客户端继续 attach 原 PTY，**不启动新 Agent**。
3. daemon 或主机重启时，checkpoint 中原本存活的受管 Agent 标记为中断。
4. Runtime 用 `codex resume <id>` 或 `claude --resume <id>` 复用原 Acro Session ID 建立新 PTY。

## 本机 dev 实例热替换

把本机正在运行的 dev app 更新到最新 main，**不丢正在跑的终端会话**。
适用于：改了桌面 UI 或 runtime（`fs.*` / `git.*` / `ports.list` / `session.*` 等 RPC 由 runtime 处理），
想立刻在本机验证。

### 1. 使用稳定身份重新打包

会 `rm -rf dist` 再 release 构建；正在跑的 PTY 有各自打开的文件句柄，不受影响。

```bash
ACRO_SIGN_IDENTITY="Developer ID Application: Zhuhai Zhiwei Network Technology Co., Ltd. (5UAHRS482C)" \
  bash apps/desktop-macos/scripts/package-app.sh <version> <build>
codesign -dvv --requirements - apps/desktop-macos/dist/Acro.app 2>&1 \
  | grep -E "TeamIdentifier=|designated"
```

输出必须包含 `TeamIdentifier=5UAHRS482C`，且 designated requirement 不得只绑定 `cdhash`。
**不要用 ad-hoc 签名做日常热替换**：每次构建都会改变 TCC 身份，导致 macOS 反复询问 App Data 等权限。

### 2. 定位进程

```bash
ps -Ao pid,ppid,pgid,command | grep -E "AcroDesktop|runtime/runtime.cjs|runtime/daemon.cjs" | grep -v grep
```

记下三个 pid，确认 daemon 的 pgid = 自身（detached）。

### 3. 只杀 UI + runtime，保留 daemon

```bash
kill <ui-pid> <runtime-pid>       # 不要杀 daemon-pid
```

用精确 pid，**别用 `pkill -f runtime`**——那会连 `daemon.cjs` 一起匹配。
attach 桥接进程会随 runtime 断连自行退出。

### 4. 干净环境启动

```bash
open apps/desktop-macos/dist/Acro.app
```

用 `open` 走 launchd 环境，不继承当前脏终端的 `NO_COLOR` / `TERM_PROGRAM` 等。

### 5. 验证

新 UI + 新 runtime（监听 8790）起来，daemon 原 pid 仍在（reparent 到 init），会话在 UI 里自动重连。

### 边界

- **要加载新 daemon 代码时才做整机重启**（连 daemon 一起杀）——那会丢所有会话。日常改 UI/runtime 不需要。
- 打包后从旧 daemon 新建终端若报 `posix_spawnp failed`（`rm -rf dist` 期间 spawn-helper 短暂消失），
  用设置里的「重启终端服务」（`daemon.restart`）在会话收尾后重启 daemon。
- 不从 cmux 等脏终端手动拉起会新建 daemon 的场景；本流程 daemon 是复用的，无此问题。

## 相关

- [RPC 与授权](./rpc.md)：`session.*` 方法与终端输入的授权
- [连接与重连](./connection.md)：客户端如何 attach 与续传

[daemon]: ../../apps/runtime/src/daemon/daemon.ts
[client]: ../../apps/runtime/src/daemon/client.ts
[index]: ../../apps/runtime/src/index.ts
