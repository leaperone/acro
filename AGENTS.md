# Acro

Acro 是团队内部使用的远程开发控制台。它管理工作区、项目、持久终端、浏览器、模拟器和 macOS Computer Use。

## 核心边界

- Mac mini 持有仓库、进程、终端会话、浏览器、模拟器和系统权限。
- iPhone、iPad、MacBook 等客户端只负责显示、输入和控制，不在本地执行开发任务。
- 不自研终端模拟器、Git 实现或网络穿透协议。优先复用 libghostty、xterm.js、@xterm/headless、系统 Git、Playwright 和安全私网。
- Workspace 是用户手动创建的工作上下文。只有用户加入 Workspace 的项目才出现在工作台中。
- Acro 不管理 Git 分支、Worktree 或提交流程。终端里的 Agent 按项目规则自行处理这些工作。
- Runtime 只校验设备和远程控制 RPC。终端输入对 Acro 不透明；Git、文件和生产操作由终端里的 Agent 按项目规则处理。

## Monorepo

- `apps/`：服务端、桌面端和移动端应用。
- `apps/desktop-macos/Vendor/`：整包搬运的 cmux SPM 包与 Bonsplit shim，见目录内 `NOTICE.md`。
- `packages/`：跨端协议和确有复用价值的共享代码。
- `.planning/`：需要跨会话维护的产品和技术蓝图。
- `.tmp/`：本地参考源码和临时文件，不进入 Git。

不要预建空应用和共享包。开始实现具体能力时再创建对应 workspace。

## 参考项目

- Orca 源码：`.tmp/orca`（MIT），上游 `https://github.com/stablyai/orca`
- cmux 源码：`.tmp/cmux`（GPL-3.0），上游 `https://github.com/manaflow-ai/cmux`
- muxy 源码：`.tmp/muxy`（MIT），上游 `https://github.com/muxy-app/muxy`
- ghostty 源码：`.tmp/ghostty`（MIT），上游 `https://github.com/ghostty-org/ghostty`
- otty 源码：`.tmp/otty`（Apache-2.0），上游 `https://github.com/otty-shell/otty`

参考目录只读。Acro 以 GPL-3.0-or-later 开源，与 cmux 许可证兼容：cmux 代码可以直接取用，保留其版权声明。首次引入 cmux 代码时，在仓库根添加 GPL-3.0-or-later 的 LICENSE。MIT / Apache 项目的代码在理解后同样可以取用并保留版权声明。不要复制不理解或不需要的代码。

## 规划入口

- Acro 蓝图：`/Users/harry/project/acro/.planning/blueprint.md`

架构边界、组件职责或验收标准发生变化时更新蓝图。普通执行进度不写入蓝图。

## 工程规则

- 使用 pnpm workspace。协议唯一真源是 `packages/protocol` 的 zod schema，Swift 端类型用 codegen 生成，禁止手工镜像。
- 优先调用项目已有的构建和 preflight 脚本，不在 Acro 中复制项目规则。
- 服务端是会话状态的唯一真相源。客户端重连不能终止服务端进程。
- 服务端逻辑使用 TypeScript；桌面客户端和 Computer Use helper 使用 Swift。
- 只为已确认的需求增加依赖、应用或抽象。

## 本机 dev 实例热替换

把本机正在运行的 dev app 更新到最新 main，**不丢正在跑的终端会话**。适用于：改了桌面 UI 或 runtime（`fs.*`/`git.*`/`ports.list`/`session.*` 等 RPC 由 runtime 处理），想立刻在本机验证。

进程模型：一个 dev 实例 = **UI**（`AcroDesktop`）+ **runtime**（`runtime.cjs`）+ **daemon**（`daemon.cjs`）。daemon 是 detached 进程（自己的 pgid），持有全部 PTY，**活过 UI/runtime 重启**。只更新 UI + runtime 就能拿到新 UI 和新 RPC；daemon 代码没变时不用动它，会话就保住。

步骤：

1. **重新打包**（会 `rm -rf dist` 再 release 构建；正在跑的 PTY 有各自打开的文件句柄，不受影响）：
   ```bash
   bash apps/desktop-macos/scripts/package-app.sh <version> <build>   # 如 0.0.8-beta.9 39
   ```
2. **定位进程**：
   ```bash
   ps -Ao pid,ppid,pgid,command | grep -E "AcroDesktop|runtime/runtime.cjs|runtime/daemon.cjs" | grep -v grep
   ```
   记下 UI、runtime、daemon 三个 pid，确认 daemon 的 pgid = 自身（detached）。
3. **只杀 UI + runtime，保留 daemon**（精确 pid，别用 `pkill -f runtime`——那会连 `daemon.cjs` 一起匹配）：
   ```bash
   kill <ui-pid> <runtime-pid>       # 不要杀 daemon-pid
   ```
   attach 桥接进程会随 runtime 断连自行退出。
4. **干净环境启动**（用 `open` 走 launchd 环境，不继承当前脏终端的 `NO_COLOR`/`TERM_PROGRAM` 等）：
   ```bash
   open apps/desktop-macos/dist/Acro.app
   ```
5. **验证**：新 UI + 新 runtime（监听 8790）起来，daemon 原 pid 仍在（reparent 到 init），会话在 UI 里自动重连。

边界：

- **要加载新 daemon 代码时才做整机重启**（连 daemon 一起杀）——那会丢所有会话。日常改 UI/runtime 不需要。
- 打包后从旧 daemon **新建终端**若报 `posix_spawnp failed`（`rm -rf dist` 期间 spawn-helper 短暂消失），用设置里的「重启终端服务」（daemon.restart）在会话收尾后重启 daemon 即可。
- 不从 cmux 等脏终端手动拉起会新建 daemon 的场景；本流程 daemon 是复用的，无此问题。见 memory `acro-daemon-clean-launch-env`。
