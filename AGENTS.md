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

参考目录只读。MIT / Apache 项目的代码在理解后可以取用并保留版权声明；cmux 是 GPL-3.0，只作交互设计和架构参考，禁止复制代码。不要复制不理解或不需要的代码。

## 规划入口

- Acro 蓝图：`/Users/harry/project/acro/.planning/blueprint.md`

架构边界、组件职责或验收标准发生变化时更新蓝图。普通执行进度不写入蓝图。

## 工程规则

- 使用 pnpm workspace。协议唯一真源是 `packages/protocol` 的 zod schema，Swift 端类型用 codegen 生成，禁止手工镜像。
- 优先调用项目已有的构建和 preflight 脚本，不在 Acro 中复制项目规则。
- 服务端是会话状态的唯一真相源。客户端重连不能终止服务端进程。
- 服务端逻辑使用 TypeScript；桌面客户端和 Computer Use helper 使用 Swift。
- 只为已确认的需求增加依赖、应用或抽象。
