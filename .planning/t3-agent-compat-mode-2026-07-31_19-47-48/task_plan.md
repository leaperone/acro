# 任务计划：t3-agent-compat-mode

- 任务 ID：`t3-agent-compat-mode-2026-07-31_19-47-48`
- 创建时间：`2026-07-31_19-47-48`

## 目标

为 Acro 增加一个与现有工作台并列的“Agent 模式”：在 Acro macOS App 内运行固定版本的 T3 Code Server，并用原生 `WKWebView` 承载其完整 Web UI，使用户获得 T3 的 Project、Thread、Provider、审批、终端、Git/worktree 和 diff 体验，同时不改变 Acro Runtime、Workspace、Session 与持久 terminal daemon 的现有语义。

Planning 已获用户确认，当前进入代码实现。

## 范围

- macOS Desktop 首版：只面向 Desktop 所在的本机执行环境，提供“工作台 / Agent”顶层模式切换，Agent 模式占据主内容区；选择远端 Acro Server 时不得把本机 T3 伪装成远端能力。
- 使用官方发布的精确版本 `t3` npm 包作为兼容运行时与 Web UI，不复制整个上游 monorepo。
- 将 T3 的发布产物、生产依赖和许可证随 Acro App 打包、签名和公证。
- Acro 原生进程负责 T3 sidecar 的启动、健康检查、认证 bootstrap、重连、显式停止和版本替换；健康 sidecar 脱离窗口生命周期继续运行。
- T3 只绑定 `127.0.0.1`，数据独立存放在 `~/.acro/t3-compat/`。
- T3 模式复用用户现有项目目录及 Codex、Claude、Cursor、Grok、OpenCode 配置，但 T3 Thread、PTY、数据库、Git/worktree 状态与 Acro Session 分离。
- 固定上游版本、完整性与许可证来源；只有官方包无法嵌入时才增加最小 pnpm patch。
- 为 sidecar 生命周期、bootstrap 安全、模式切换、打包和不影响 Acro daemon 建立自动化与人工验收。

## 非目标

- 不让 T3 UI attach 或控制已有 Acro PTY；不设计双向 Session/Thread 同步协议。
- 不把 T3 的 Effect、事件投影、Provider Registry、Git/worktree 模型迁入 Acro Runtime。
- 不把现有 SwiftUI/Ghostty 工作台替换为 React/Electron。
- 不复制 T3 名称、Logo、商标、营销素材或云端 T3 Connect 服务。
- 首版不提供 Acro Mobile 内嵌 Agent 模式，不为 WKWebView 缺失的 Electron 专属能力重写兼容层。
- 首版不通过 Acro E2EE/WebSocket 隧道代理远端 T3 HTTP/WS，也不承诺重启 Mac 后自动恢复运行中的 T3 进程。
- 不在本任务中补齐 Acro Browser、Simulator 或 Computer Use 的既有客户端入口。
- 不自动跟随 `latest`；T3 升级必须通过明确依赖更新和完整回归。

## 关键约束

- 保留 Acro 当前默认体验和数据：启用、退出或崩溃 Agent 模式都不能终止 Acro terminal daemon 或已有 Session。
- Agent 模式首版必须标明“本机”；远端 Acro Server 选中时隐藏或禁用入口，并说明需要在该执行主机运行兼容服务。
- 复用 Acro 已打包并签名的 Node；不额外携带第二套 Node/Electron Runtime。
- 认证 token 只通过子进程 stdin（`--bootstrap-fd 0`）和原生 HTTP bootstrap 交换传递，不进入 URL、日志、UserDefaults 或 Web JavaScript。
- T3 sidecar 只监听 loopback；首版不开放 LAN、公网、Tailscale、SSH 或 Relay 入口。
- T3 状态目录权限为 `0700`，敏感文件遵循上游权限并纳入卸载/诊断说明。
- `t3` 依赖使用精确版本和 lockfile integrity，不使用 `^`、`latest` 或运行时 `npx` 下载。
- MIT 代码可进入 GPL-3.0-or-later 的 Acro，但必须保留 T3 Tools Inc. 版权、MIT 文本及实际分发依赖的许可证。
- 上游 Web UI 在 WKWebView 中按 web 能力运行；Electron-only Preview/SSH/桌面 IPC 不得被伪装成可用。
- 保持改动直接：一个很薄的兼容 package、一个 sidecar manager、一个 WebView surface，不建立通用插件系统。

## 修改路径

### 1. 固定兼容运行时

- 实施开始时先更新 `.planning/blueprint.md`，补充双体验模式、T3 sidecar 边界、状态隔离和首版非目标；`AGENTS.md` 继续只引用蓝图，不复制设计正文。
- 新增 `apps/t3-compat/package.json`，只声明精确版本的 `t3` 依赖和最小的产物/许可证校验脚本。
- 更新 `pnpm-lock.yaml`；继续使用现有 `apps/*` workspace 规则。
- 校验官方包包含 `dist/bin.mjs` 和静态 Web 资源；若发布包已经自包含 JS 依赖，只复制运行闭包中实际需要的文件。原生 `node-pty` 继续按 Acro 现有签名方式处理。
- 不创建 T3 源码 subtree。若确有无法通过公开 CLI/HTTP 契约解决的嵌入阻塞，先用 `pnpm patch` 留下最小、可重放差异及上游 commit 指针。

### 2. 打包与第三方声明

- 扩展 `apps/desktop-macos/scripts/package-app.sh`：构建/收集 T3 production closure 到 `Contents/Resources/t3-compat/`，检查入口、静态资源和 native module 执行权限。
- 将 T3 使用的 `.node`、helper 和其他 Mach-O 纳入现有逐个签名与签名验证，不依赖 `codesign --deep` 掩盖遗漏。
- 新增或扩展仓库级 `THIRD_PARTY_NOTICES.md`，记录 `pingdotgg/t3code`、固定版本/commit、MIT 版权、源码地址和分发依赖许可证；不复制品牌资源。
- 在打包烟测中断言 App 不依赖开发 checkout、全局 `t3` 或联网下载。

### 3. Sidecar 生命周期

- 新增 `apps/desktop-macos/Sources/T3CompatManager.swift`，复用现有 runtime/daemon 的成熟模式：单实例、健康探测、失败退避、独立进程组、可重新附着、只终止自己拉起且身份匹配的进程。
- 使用系统 loopback socket 选择空闲端口，生成随机 desktop bootstrap token，并通过 stdin 写入 T3 `DesktopBackendBootstrap` JSON；启动参数固定为 desktop/loopback/no-browser/独立 base-dir。
- 读取 T3 ready/health 状态后才开放 UI；启动失败显示可重试诊断，不影响 Acro 工作台。
- 模式切换和 Acro Desktop 退出都不终止健康 sidecar，避免活跃 Thread/PTY 随窗口消失；下次启动通过 T3 runtime state、PID、版本和 base-dir 重新附着。
- 只有用户显式停止、版本替换或身份验证失败时才终止兼容 sidecar；更新前显示活跃任务中断边界。
- 如果同一状态目录已有可验证的兼容 T3 实例，复用它；PID、版本、base-dir 或健康不一致时不得误杀外部进程。

### 4. 原生认证与 WebView

- 新增 `apps/desktop-macos/Sources/T3CompatView.swift`，用 `WKWebView` 加载 loopback T3 Web UI。
- Acro 原生代码调用 `/api/auth/browser-session` 消费 desktop bootstrap credential，将返回的 HttpOnly cookie 写入专用 `WKWebsiteDataStore` 后再加载首页；token 不注入页面。
- 导航策略只允许当前 loopback origin 在内嵌视图中打开；外部 HTTP(S) 链接交给系统浏览器，自定义 scheme 默认拒绝。
- Web 进程崩溃、sidecar 重启或 cookie 失效时重新 bootstrap；错误页保留“重试”和“返回工作台”。
- 首版明确隐藏或显示“不受支持”的 Electron-only 功能，不增加伪造 IPC。

### 5. 模式入口与状态

- 在 `WorkbenchView`/顶层窗口路由加入两值体验模式：现有 Acro 工作台与 Agent 模式。
- 模式入口只在本机执行环境可用；当前上下文指向远端 Runtime 时，不自动切换目标、不在本机打开同名项目。
- 使用现有命令系统增加菜单、命令面板和可发现的 UI 切换入口；提供始终可用的返回工作台路径。
- 只持久化最后选择的模式，不把 T3 内部导航、Thread 或 Provider 状态镜像到 Acro 模型。
- 切换时保持现有 `RuntimeHub`、Bonsplit controller、Ghostty surface 和 terminal daemon 原样存活。

### 6. 自动化验证

- Swift 单测：端口/bootstrap envelope、状态机、进程归属、失败退避、模式持久化和导航 allowlist。
- HTTP/WKWebView 契约测试：token 不在 URL/日志、browser session cookie 成功、失效后可恢复。
- 打包契约：入口/静态资源存在，native module 可加载且已签名，删除开发 checkout 后仍可启动。
- 回归：Agent 模式启动、切回工作台和 sidecar 崩溃都不改变 Acro daemon PID；既有终端继续收发输出。
- 上游升级检查：固定版本变化必须重新执行 provider、Thread、审批、终端、Git/worktree、diff、重启持久化和签名验证。

## 验证方式

- `pnpm check` 与新增 `@acro/t3-compat` 产物/许可证检查通过。
- `swift test --package-path apps/desktop-macos` 通过新增生命周期、模式和导航测试。
- 使用 ad-hoc 包执行完整 packaging smoke；正式发布前使用稳定 Developer ID 验证嵌套 native module、App 签名、公证与 Gatekeeper。
- 在没有全局 `t3`、没有 `.tmp/t3code`、网络断开的环境启动打包 App，Agent 模式仍能打开。
- 在 Agent 模式创建项目和 Thread，分别验证已安装 Provider 的新会话、流式消息、工具调用、审批/用户输入、终端、Git 状态、worktree 和 diff。
- Agent 模式与工作台往返切换，确认 Acro 既有终端进程、cwd、布局和输出连续；T3 Thread 状态也不因切换丢失。
- 退出并重新打开 Acro Desktop，确认仍可附着同一 T3 sidecar，活跃任务和终端继续运行；重启 Mac 后只要求持久 Thread 可重新打开，不虚构 live PTY 恢复。
- 终止 T3 sidecar 后验证错误提示与恢复；终止/更新 Acro Runtime 时验证 T3 与 Acro daemon 的边界符合设计。
- 检查进程参数、日志、URL、UserDefaults 和 state 文件，确认 bootstrap token 未泄露且 sidecar 只监听 loopback。
- 人工视觉验收窄窗、全屏、深浅色、键盘焦点、复制粘贴、IME、外链和返回工作台入口。

## 验收标准

- 用户可在同一个 Acro 窗口明确切换“工作台 / Agent”，现有工作台行为无回归。
- Agent 模式明确标注并仅操作 Desktop 本机；远端 Server 上下文不会静默落到本机目录或凭据。
- Agent 模式展示 T3 的真实 Web UI，而不是仿制 SwiftUI 页面；核心 Thread/Provider/审批/终端/Git 流程可用。
- T3 不要求用户预装、手动启动或在线下载 `t3`。
- T3 与 Acro 使用独立状态和进程模型；任一 sidecar 故障不会杀死另一方的会话。
- 关闭并重开 Acro Desktop 不终止健康 T3 sidecar；应用可验证身份后重新附着。
- Acro terminal daemon 在模式切换和 T3 sidecar 重启前后保持同一 PID，活跃终端无输出丢失。
- T3 bootstrap credential 不出现在 URL、日志和 Web JavaScript；服务仅监听 loopback。
- 发布包包含完整版权/许可证声明，未使用 T3 品牌素材。
- 打包、签名、公证、启动和离线 smoke 均有可重复证据。
- T3 版本升级是显式依赖变更，有固定回归清单，不存在静默 `latest` 漂移。

## 未确认事项

没有则写“无”。

- 无。首版按“本地 macOS、隔离状态、官方包、WKWebView、核心 Web 能力”实施；共享 Acro PTY、Mobile 和 Electron-only 能力若后续被明确要求，再单独 planning。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成兼容模式实施规划
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 使用固定的官方 `t3` npm 包，不复制整个仓库 | 保留原版 UI/行为，lockfile 可复现，避免长期维护大体量 fork |
| T3 作为独立 loopback sidecar | 不污染 Acro Runtime/协议，也不危及持久 terminal daemon |
| 使用 `WKWebView` 而非 Electron | 复用 macOS 原生能力和 Acro 已有 Node，避免携带第二套桌面 Runtime |
| 原生交换 browser session cookie | bootstrap token 不进入 URL或 Web JavaScript |
| T3 与 Acro 状态完全隔离 | 避免 Thread/Session、PTY 和 Git 所有权冲突 |
| 首版只保证 Web 能力 | Electron Preview/SSH IPC 需要额外平台桥，不应伪装兼容 |
| 只在必要时使用 pnpm patch | 保持上游升级简单，拒绝预先维护 fork |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | planning 阶段未发生错误 |
