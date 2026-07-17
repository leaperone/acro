# Acro 产品与技术蓝图

## 目标

Acro 是远程优先的开发控制台。开发任务实际运行在 Mac mini。用户可以从 MacBook、iPhone 或 iPad 查看并控制同一批项目、Worktree、终端、浏览器和模拟器。

Acro 不是新的 Shell、IDE 或远程桌面。它负责把现有开发工具组织成可以持久运行、断线重连和跨设备控制的会话。

## 产品原则

1. 服务端持有状态：客户端关闭或断网后，开发进程继续运行。
2. Worktree 持有任务：每个任务的终端、端口、浏览器和模拟器状态都归属一个 Worktree。
3. 项目规则优先：创建、验证、提交和清理优先调用仓库已有脚本。
4. 客户端保持轻薄：客户端不克隆代码，也不运行构建、Agent 或 SSH 服务。
5. 权限集中控制：Git 写操作、命令执行和 Computer Use 都由 Mac mini 校验。

## 非目标

- 自研终端渲染器或 Shell。
- 自研 VPN、NAT 穿透或云中继。
- 替代 GitHub、Git、Codex、Claude Code、Playwright 或 Xcode Simulator。
- 第一阶段支持 Windows、Linux 服务端、多人实时协作或插件市场。

## 系统结构

```text
MacBook / iPhone / iPad
  Desktop / Mobile Client
           |
     HTTPS + WebSocket
           |
Mac mini Acro Runtime
  Project and Worktree Manager
  Persistent Terminal Sessions
  Browser Runtime
  Simulator and Computer Use Helper
```

### Mac mini Runtime

使用 Node.js 和 TypeScript，作为登录用户的 macOS LaunchAgent 常驻运行。

职责：

- 发现项目和 Worktree，调用系统 Git 与仓库自带脚本。
- 管理持久终端。使用 tmux 保存会话，使用 node-pty 接入终端数据。
- 运行 Codex、Claude Code、开发服务器和普通命令。
- 使用 Playwright 管理运行在 Mac mini 上的 Chromium。
- 调用 Swift helper 完成窗口发现、截图、输入和应用唤醒。
- 调用 `xcrun simctl` 管理 Apple 模拟器。
- 保存设备、项目、会话、布局引用和审计记录。

### Desktop Client

使用 Electron、React 和 xterm.js。

职责：

- 工作区、标签页、分屏和快捷键。
- 终端、浏览器、模拟器和 Computer Use 表面。
- 本地窗口状态。真实进程状态始终来自 Runtime。

### Mobile Client

使用 Expo 和 React Native。终端区域通过 WebView 复用 xterm.js。

职责：

- 查看任务和 Agent 状态。
- 连接、输入、审批和接收通知。
- 提供适合触屏的 Esc、Ctrl、Tab、方向键和组合键入口。
- 安全保存设备凭据，不保存仓库和服务端密钥。

### Swift Helper

保持为独立小进程，只提供 TypeScript 无法可靠完成的 macOS 能力：

- Accessibility API 操作。
- ScreenCaptureKit 画面采集。
- 键盘和指针事件。
- 应用、窗口和 Simulator 激活。

它必须运行在已登录的图形用户会话中，并显式取得辅助功能和录屏权限。

## 核心数据模型

```text
Machine
  Project
    Worktree
      Session
        Surface
```

- `Machine`：实际执行任务的 Mac。
- `Project`：Git 仓库及其项目规则。
- `Worktree`：分支对应的隔离工作目录。
- `Session`：可持久运行和重连的任务会话。
- `Surface`：终端、浏览器、模拟器或 Computer Use 画面。

## 通信与安全

- 内部使用安全私网连接，不向公网暴露 Runtime 端口。
- 首次连接使用一次性配对码，之后使用设备密钥。
- HTTP 处理查询和命令；WebSocket 传输终端、状态事件和画面帧。
- 控制消息使用共享 TypeScript 类型；终端数据使用二进制帧。
- 服务端为每个写操作检查设备、项目、Worktree 和操作类型。
- 删除、强推、覆盖文件、生产操作和 Computer Use 必须执行项目级安全规则。

## 关键流程

### 创建任务

1. 用户选择项目和 base。
2. Runtime 优先调用项目已有 Worktree 脚本，否则调用系统 `git worktree`。
3. Runtime 建立持久终端并在新 Worktree 中启动 Agent。
4. 客户端打开该 Worktree 的终端布局。

### 运行与预览

1. Runtime 在 Worktree 中启动开发服务。
2. Runtime 在 Mac mini 上打开 Chromium，并访问对应 localhost。
3. 客户端显示浏览器画面并把输入发送回 Runtime。
4. 需要移动端时，Runtime 启动 Simulator 并附加对应画面。

### 断线重连

1. 客户端记录最后收到的事件序号。
2. Runtime 保持终端和后台进程运行。
3. 客户端重连后获取当前快照，再补齐后续事件。
4. 客户端布局可以不同，但引用相同的服务端 Session。

## 首个可用闭环

Acro 达到以下结果时，基础架构成立：

1. iPhone 配对 Mac mini。
2. 从 iPhone 选择一个项目并创建 Worktree。
3. 在该 Worktree 中启动 Codex 和开发服务器。
4. 从 iPhone 查看终端和 Mac mini 上的 localhost。
5. 从 iPhone 唤醒 Simulator，并查看对应画面。
6. iPhone 断网后重连，终端、Agent 和开发服务器保持运行。
7. 同一会话可以从 MacBook Desktop Client 接管。

## 实现顺序

1. Runtime、设备配对和项目发现。
2. Worktree 与持久终端。
3. Desktop Client 的工作区、分屏和快捷键。
4. 服务端 Chromium 和浏览器表面。
5. Mobile Client 和断线重连。
6. Swift helper、Simulator 和 Computer Use。

每一步只增加完成当前闭环所需的 workspace 和依赖。

## 主要风险

- macOS 辅助功能、录屏权限以及锁屏后的行为。
- 移动网络下的终端顺序、背压和画面延迟。
- 多客户端同时调整终端尺寸和输入时的所有权。
- 仓库自定义 Worktree 流程与通用 Git 行为的差异。
- 远程命令和 Computer Use 权限过大导致的安全风险。

这些风险必须通过真实 Mac mini、iPhone 和 MacBook 的端到端验证解决，不能只靠单元测试或桌面本地演示判断。

## 参考

- Orca 本地源码：`/Users/harry/project/acro/.tmp/orca`
- Orca 上游：`https://github.com/stablyai/orca`
- cmux 本地源码：`/Users/harry/project/acro/.tmp/cmux`
- cmux 上游：`https://github.com/manaflow-ai/cmux`
