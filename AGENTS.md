# Acro

Acro 是团队内部使用的远程开发控制台。它管理项目、Git Worktree、持久终端、浏览器、模拟器和 macOS Computer Use。

## 核心边界

- Mac mini 持有仓库、进程、终端会话、浏览器、模拟器和系统权限。
- iPhone、iPad、MacBook 等客户端只负责显示、输入和控制，不在本地执行开发任务。
- 不自研终端模拟器、Git 实现或网络穿透协议。优先复用 xterm.js、系统 Git、tmux、Playwright 和安全私网。
- Worktree 是任务隔离单元。终端、浏览器和模拟器必须归属明确的项目与 Worktree。
- 高危 Git、文件和系统操作必须在服务端校验，不能只依赖客户端确认。

## Monorepo

- `apps/`：服务端、桌面端和移动端应用。
- `packages/`：跨端协议和确有复用价值的共享代码。
- `.planning/`：需要跨会话维护的产品和技术蓝图。
- `.tmp/`：本地参考源码和临时文件，不进入 Git。

不要预建空应用和共享包。开始实现具体能力时再创建对应 workspace。

## 参考项目

- Orca 源码：`/Users/harry/project/acro/.tmp/orca`
- 上游仓库：`https://github.com/stablyai/orca`
- cmux 源码：`/Users/harry/project/acro/.tmp/cmux`
- 上游仓库：`https://github.com/manaflow-ai/cmux`

Orca 和 cmux 只用于研究产品结构和实现方式。不要直接修改参考目录，也不要复制不理解或不需要的代码。

## 规划入口

- Acro 蓝图：`/Users/harry/project/acro/.planning/blueprint.md`

架构边界、组件职责或验收标准发生变化时更新蓝图。普通执行进度不写入蓝图。

## 工程规则

- 使用 pnpm workspace，保持 TypeScript 协议类型跨端共享。
- 优先调用项目已有的 Worktree、构建和 preflight 脚本，不在 Acro 中复制项目规则。
- 服务端是会话状态的唯一真相源。客户端重连不能终止服务端进程。
- Computer Use 原生能力放在小型 Swift helper 中，其余逻辑优先使用 TypeScript。
- 只为已确认的需求增加依赖、应用或抽象。
