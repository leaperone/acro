# Acro 产品与技术蓝图

## 目标

Acro 是远程优先的开发控制台。开发任务实际运行在 Mac mini。用户可以从 MacBook、iPhone 或 iPad 查看并控制同一批 Workspace、项目、终端、浏览器和模拟器。

Acro 不是新的 Shell、IDE 或远程桌面。它负责把现有开发工具组织成可以持久运行、断线重连和跨设备控制的会话。

## 产品原则

1. 服务端持有状态：客户端关闭或断网后，开发进程继续运行。
2. Workspace Group 组织多个 Workspace；Workspace 保存一个具体工作上下文，并引用需要的项目和会话。
3. Agent 管理 Git：Acro 不创建分支或 Worktree，终端里的 Agent 按仓库规则自行处理 Git 工作流。
4. 客户端保持轻薄：客户端不克隆代码，也不运行构建、Agent 或 SSH 服务。
5. 远程控制集中鉴权：Runtime 校验设备、Workspace 和控制 RPC；终端内命令由 Agent 与项目规则负责。
6. 左侧导航以 Workspace 为默认层级。Tab、终端和分屏属于 Workspace 内部布局，不默认展开为全局导航项；客户端可切换到会话详情视图查看终端列表。

## 非目标

- 自研终端渲染器或 Shell。
- 自研 VPN、NAT 穿透或云中继。
- 替代 GitHub、Git、Codex、Claude Code、Playwright 或 Xcode Simulator。
- 解析、代理或管理 Git 分支、Worktree、提交和合并流程。
- 多人实时协作、插件市场,以及原生 Windows(非 WSL)服务端。

## 系统结构

```text
MacBook / iPhone / iPad
  Desktop / Mobile Client
           |
     HTTPS + WebSocket
           |
Mac mini Acro Runtime
  Workspace and Project Registry
  Persistent Terminal Sessions
  Browser Runtime
  Simulator and Computer Use Helper
```

### Mac mini Runtime

使用 Node.js 和 TypeScript，作为登录用户的 macOS LaunchAgent 常驻运行。

职责：

- 浏览 Runtime 文件系统并保存用户显式注册的项目目录、Workspace Group 与 Workspace。项目选择默认从 Runtime 的用户主目录开始，也可切换到根目录或直接输入路径；不扫描固定的 `~/project` 目录。
- 管理持久终端。终端由独立 terminal daemon 进程持有：node-pty 驱动 PTY，服务端 headless 终端维护屏幕状态，checkpoint 落盘。Runtime 升级或崩溃不影响会话。daemon 实现大量取用 orca（MIT）的代码。
- 运行 Codex、Claude Code、开发服务器和普通命令。Acro 创建的 Agent 通过 provider hook 上报状态与 provider session id；terminal daemon 中断后，Runtime 使用 provider 原生 resume 命令恢复同一个 Acro Session。Acro 不解析终端输出，也不编排 Agent 内部工具或 Git 工作流。
- 使用 Playwright 管理运行在 Mac mini 上的 Chromium。
- 调用 Swift helper 完成窗口发现、截图、输入和应用唤醒。
- 调用 `xcrun simctl` 管理 Apple 模拟器。
- 保存设备、Workspace Group、Workspace、项目引用、会话、布局引用和审计记录。

Runtime 逻辑跨平台:也可作为登录用户的 systemd service 常驻在 Linux 服务器或 Windows WSL 上(见 `scripts/install-systemd.sh` 与安装教程 `docs/linux-wsl-server.md`)。此时终端、文件、Git、端口、配对与断线重连原样工作;iOS 模拟器与 Computer Use 是 macOS 专有,不可用;浏览器视 Chromium 是否安装。这些能力差异待桌面端引入对应表面时,再由 `server.info` 能力协商在客户端按平台隐藏。node-pty 的原生绑定需在目标机 `pnpm install` 现编,故服务端按 OS/架构分别打包,不产出单一跨平台二进制。

### Desktop Client

原生 macOS 应用，使用 Swift 和 SwiftUI。终端渲染嵌入 libghostty：`acro attach` CLI 把 Runtime 的 WebSocket 会话桥接到 surface command（cmux 验证过的模式，集成方式取自 muxy）。交互设计对标 cmux：可折叠 Workspace Group、组内 Workspace、垂直标签、通知环和命令面板。

职责：

- 工作区、标签页、分屏和快捷键。
- 左侧栏默认只投影 Workspace；会话详情是客户端视图偏好，不进入 Runtime 数据模型。
- 终端、浏览器、模拟器和 Computer Use 表面。
- 右侧栏只读数据面板（上下文 / 文件 / Git / 端口 + 文件内容搜索）：文件树、文件预览、内容搜索、Git 状态与 diff、监听端口全部经 Runtime 的只读 RPC 家族（`fs.*` / `git.*` / `ports.list`）从 Mac mini 取，客户端只显示。**只读**——列目录、读文件、grep、git status/diff、lsof 属于"显示"，不越界；写 / stage / commit / kill 等变更仍归终端里的 Agent。UI 对标 cmux 右侧栏与 orca source-control；不移植 cmux/orca 里绑其 agent 编排框架的模式（会话历史 / 活动流 / dock / 自定义侧栏）。
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
  Workspace Group
    Workspace
      Project reference
      Session
        Surface
  Project
```

- `Machine`：实际执行任务的 Mac。
- `Workspace Group`：用户创建的界面组织层，只负责聚合 Workspace；它不对应仓库、分支或 Worktree，解散分组不会删除 Workspace。
- `Workspace`：用户创建的工作上下文，引用项目并持有会话和布局。
- `Project`：项目目录引用，只用于选择终端工作目录；Acro 不保存分支或 Worktree 状态。
- `Session`：可持久运行和重连的任务会话；Acro 管理的 Codex / Claude Session 可附带 provider 状态、恢复身份和中断标记。
- `Surface`：终端、浏览器、模拟器或 Computer Use 画面。

## 通信与安全

- 传输安全不依赖 TLS：所有连接走应用层 E2EE（X25519 + HKDF-SHA256 + ChaCha20-Poly1305），可以安全经过 LAN 或 FRP 等明文公网代理。Acro 不自研穿透，公网入口由用户的代理软件提供。
- 配对采用访问授权模型（取自 orca）：服务端生成配对码 `acro://pair?c=…`，内含入口列表、设备 token 和服务端公钥，由用户带外传输；token 只在加密信道内认证，服务端只存哈希。授权可撤销，撤销立即断开该设备的活动连接。
- 一个远程 Runtime 对客户端 = 一个 token + 多个入口（LAN、公网代理），局域网优先、失败自动回退公网；从任何入口连上都是同一设备身份、同一批会话，服务端不区分连接来源。
- 桌面客户端是多主机的：为每台已配对 Runtime 维持一条常驻连接（RuntimeHub），侧边栏按服务器分组同时显示各自的工作区；终端 attach 通过 CLI `--server` 路由到对应 Runtime。CLI 随桌面 App 打包成单文件，客户端机器不需要仓库 checkout。
- 每个客户端与 Runtime 之间只有一条 WebSocket：控制消息使用 zod 定义的 JSON-RPC，终端数据使用二进制帧，事件带 `seq` 和 `boot_id` 支持断点续传。HTTP 只保留健康检查。
- 协议唯一真源是 `packages/protocol` 的 zod schema；Swift 客户端类型用 codegen 生成，禁止手工镜像。
- 客户端 attach 会话时先收快照再收增量；多客户端输入所有权由 Runtime 仲裁。
- 服务端为每个控制 RPC 检查设备、Workspace、项目归属和操作类型。
- 终端字节流对 Acro 不透明。Git、文件修改和生产命令的安全规则由终端里的 Agent 与项目规则执行，Acro 不解析或拦截 Shell 命令。

## 关键流程

### 创建任务

1. 用户创建或选择 Workspace Group，在组内创建 Workspace，并从 Runtime 文件系统选择目标项目目录。
2. Runtime 注册项目、加入 Workspace，并在该目录建立持久终端启动 Agent。
3. Agent 按仓库规则自行创建分支或 Worktree。
4. 客户端在 Workspace 中打开终端布局。

### 运行与预览

1. Agent 在自己选择的工作目录中启动开发服务。
2. Runtime 在 Mac mini 上打开 Chromium，并访问对应 localhost。
3. 客户端显示浏览器画面并把输入发送回 Runtime。
4. 需要移动端时，Runtime 启动 Simulator 并附加对应画面。

### 断线重连

1. 客户端记录最后收到的事件序号。
2. Runtime 保持终端和后台进程运行。
3. 客户端重连后获取当前快照，再补齐后续事件。
4. 客户端布局可以不同，但引用相同的服务端 Session。

### Agent 冷恢复

1. Provider hook 把 Codex / Claude 的 session id 和状态写入终端 Session checkpoint。
2. Runtime 重启但 terminal daemon 存活时，客户端继续 attach 原 PTY，不启动新 Agent。
3. terminal daemon 或主机重启时，checkpoint 中原本存活的受管 Agent 标记为中断。
4. Runtime 使用 `codex resume <id>` 或 `claude --resume <id>`，复用原 Acro Session ID 建立新 PTY。

## 首个可用闭环

Acro 达到以下结果时，基础架构成立：

1. iPhone 配对 Mac mini。
2. 从 iPhone 创建 Workspace 并加入一个项目。
3. 在项目终端中启动 Codex 和开发服务器。
4. 从 iPhone 查看终端和 Mac mini 上的 localhost。
5. 从 iPhone 唤醒 Simulator，并查看对应画面。
6. iPhone 断网后重连，终端、Agent 和开发服务器保持运行。
7. 同一会话可以从 MacBook Desktop Client 接管。

## 实现顺序

1. Runtime、设备配对和项目发现。
2. Workspace 与终端 daemon（持久会话、快照、`seq` 续传）。
3. Swift Desktop Client 的工作区、分屏、快捷键和 libghostty attach。
4. 服务端 Chromium 和浏览器表面。
5. Mobile Client 和断线重连。
6. Swift helper、Simulator 和 Computer Use。

每一步只增加完成当前闭环所需的 workspace 和依赖。

## 主要风险

- macOS 辅助功能、录屏权限以及锁屏后的行为。
- 移动网络下的终端顺序、背压和画面延迟。
- 多客户端共享终端时，输入 owner 同时决定 PTY 尺寸；观察端 resize 不得干扰操作端。
- Agent 在不同仓库中执行 Git 工作流时的行为差异。
- 远程命令和 Computer Use 权限过大导致的安全风险。

这些风险必须通过真实 Mac mini、iPhone 和 MacBook 的端到端验证解决，不能只靠单元测试或桌面本地演示判断。

## 参考与取材规则

| 项目 | 本地路径 | License | 用途 |
|---|---|---|---|
| orca | `.tmp/orca` | MIT | 服务端代码来源：terminal daemon、RPC、编排模型可直接取用 |
| cmux | `.tmp/cmux` | GPL-3.0 | Acro 以 GPL-3.0-or-later 开源，代码可直接取用并保留版权声明；巨型 app 层（AppDelegate/ContentView）只抄逻辑不整搬 |
| muxy | `.tmp/muxy` | MIT | SwiftUI + libghostty 集成与移动端远程协议的代码来源 |
| ghostty | `.tmp/ghostty` | MIT | libghostty 上游，xcframework 构建方式 |
| otty | `.tmp/otty` | Apache-2.0 | Rust 终端工作台，快照帧与后端抽象参考 |

MIT / Apache 项目的代码在理解后可以取用并保留版权声明。libghostty 没有喂字节 API，远程会话必须走 attach CLI 作 surface command 的模式；embedding API 不稳定，需 pin ghostty fork。

cmux 取材要点（调研结论）：侧边栏行必须走 snapshot 边界（行视图只收 Equatable 值快照 + 闭包动作包，不持 ObservableObject）；不加 display link 或手动 surface_draw 轮询；注意力闪环、命令面板 overlay、快捷键提示 pill 可直接取用。orca 取材要点：WS 心跳回收半开连接、客户端重连退避 + 探针式探活、快照与增量 seq 同轮对齐。
