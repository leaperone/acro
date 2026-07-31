# 调研与结论：t3-agent-compat-mode

- 任务 ID：`t3-agent-compat-mode-2026-07-31_19-47-48`
- 创建时间：`2026-07-31_19-47-48`

## 需求事实

- 用户明确认为 T3 Code 的使用体验很好，希望 Acro 增加一个兼容模式并复用其代码。
- Acro 现有核心边界是服务端持有状态、透明终端、Agent 自己管理 Git；兼容模式不能替换或暗改这些语义。
- 用户先要求 planning，确认方案后以 `go` 授权进入实现；本次包含代码与验证，但不发布 Desktop。
- T3 Code 当前审计版本为 npm `t3@0.0.31`，参考仓库 HEAD 为 `ef4ec2ad4b9b08d1aca31d68aea28f0a846ef295`。

## 真实调用链

- T3 `apps/server/src/cli/server.ts` 的 `serve`/`start` 最终调用 `runServer`；Server 同时提供 HTTP、WebSocket 和构建后的完整 Web UI。
- `apps/server/src/cli/config.ts` 支持 `--mode`、`--host`、`--port`、`--base-dir`、`--no-browser` 和 `--bootstrap-fd`；desktop 模式默认 loopback。
- `packages/contracts/src/desktopBootstrap.ts` 定义 desktop bootstrap envelope，包括端口、host、base dir 和 desktop bootstrap token。
- T3 Desktop 自身通过 `DesktopBackendManager` 启动同一个 `dist/bin.mjs`，并支持在 macOS/Linux 使用 fd3、在受限环境使用 stdin 传 bootstrap 数据；Acro 可直接采用 stdin 路径。
- T3 browser session 通过 `/api/auth/browser-session` 把 bootstrap credential 换成 HttpOnly cookie，适合由 Acro 原生层完成后交给 WKWebView。
- Acro `LocalRuntimeManager` 已经实现 bundled Node 查找、子进程归属、健康检查、失败退避和日志，是 T3 sidecar manager 的直接复用模式；唯一区别是健康 T3 sidecar 不随 App 退出清理。
- Acro `package-app.sh` 已复制 runtime 依赖，并逐个签名 Node、`.node` 和 `spawn-helper`；T3 的 native closure 应进入同一签名/验证链。
- Acro terminal daemon 是 detached 进程，UI/Runtime 重启不会终止 PTY；兼容模式必须保持这一进程和现有连接不变。

## 调研结论

- npm `t3@0.0.31` 的 integrity 为 `sha512-2z5cpQSTcYATBHomHQLD/W8Ifv/lhbT4O6af5V/olgliXliX7aaHgNB4J3lzJp4mBSZ8cyqT6ZatYbGqqitctg==`，包体约 15.8 MB、解包约 75.5 MB，包含 `dist/bin.mjs`、`dist/client/index.html` 和 MIT `LICENSE`。
- T3 声明 Node `^22.16 || ^23.11 || >=24.10`；Acro 当前打包脚本复制 PATH 中的 Node，实施必须增加版本闸，不能只检查可执行性。
- `POST /api/auth/browser-session` 的请求体只有 `{ "credential": <token> }`；响应通过 `Set-Cookie` 写入 HttpOnly、SameSite=Lax、path `/` 的 session cookie，原生 WKWebView bootstrap 无需注入 JavaScript。
- 显式 `--base-dir` 的 runtime state 位于 `<baseDir>/userdata/server-runtime.json`，包含 PID、port、origin 和 startedAt，可用于安全重新附着。
- 技术上可行，且无需把 T3 的 React UI 逐页翻译成 SwiftUI：官方 Server 已经提供完整 Web UI。
- 最小可靠集成不是复制整个 T3 monorepo，而是固定官方 `t3` 包，将其发布产物作为 Acro 的内部 sidecar。这样最接近原版体验，也保留明确升级边界。
- `WKWebView` 是 macOS 原生能力，无需新增桌面框架；T3 核心 Web 体验可以运行，但 Electron 专属 `<webview>` Preview、SSH manager 和 IPC 能力不会自动存在。
- 直接共享 Acro PTY 会要求桥接 T3 TerminalManager、Provider session、event log 和 Acro daemon，属于另一套架构，不应进入首版。
- T3 与 Acro 都使用 `node-pty`，但不能因此共享进程所有权；两个 manager 各自持有自己的 PTY 是最安全的兼容边界。
- Acro Desktop 可连接远端 Runtime，而嵌入的 loopback T3 Web UI 只能表示 Desktop 本机；首版必须明确 local-only，不能依据当前选中的远端 Workspace 猜测或映射本机路径。
- T3 Server 可作为独立进程运行，因此没有必要在 Desktop 退出时主动杀死它；复用 runtime state 和进程身份即可在下次启动重新附着，并保留活跃任务。
- T3 为 MIT，能够分发在 GPL-3.0-or-later 的 Acro 中；代码许可不自动授予商标和品牌素材使用权。
- Acro 已内置 Node，新增 Electron 或运行时 `npx` 都是不必要的体积、供应链和签名风险。

## 技术决策

| 决策 | 证据 |
|---|---|
| 使用 npm 精确版本而非源码 subtree | T3 官方发布包的唯一文件入口是 `dist`，CLI 已承载 Server 和 Web UI；完整仓库包含大量开发、移动、营销和基础设施代码 |
| 新增薄 `apps/t3-compat` workspace | Acro 使用 pnpm workspace；独立 package 可固定版本、lockfile integrity 和 packaging closure，而不污染 runtime 依赖 |
| sidecar 独立 state dir | T3 Server 自己拥有项目、Thread、Provider、终端、Git 与 SQLite 状态，与 Acro Workspace/Session 模型不同 |
| loopback + native bootstrap | T3 desktop contract已有 bootstrap fd 和 browser-session 认证，不需要自定义弱认证或在 URL 携带 token |
| 模式切换不停止 sidecar | 保留活跃 T3 Thread，并避免重复 bootstrap |
| Desktop 退出也不停止健康 sidecar | T3 Server 能独立运行；这保留 Acro“窗口关闭不终止工作”的产品原则 |
| 首版 local-only | Acro 远端链路是自有 E2EE WebSocket，不能直接承载 T3 的 HTTP/WS 与 cookie 认证 |
| 不宣称 Electron-only 兼容 | T3 Preview contract明确由 Electron `<webview>` renderer 持有；WKWebView 不是 Electron IPC 环境 |
| 不复制 T3 品牌 | MIT 许可覆盖代码，不等同于商标许可；产品入口使用 Acro “Agent 模式”命名 |

## 风险与边界

- 初次安装触发 pnpm `ERR_PNPM_IGNORED_BUILDS`：`msgpackr-extract@3.0.4` 是可选 native 加速，T3 可使用纯 JS fallback。显式设为 `allowBuilds: false`，不把非必要二进制带入 Acro 签名面。
- T3 官方包可能将某些依赖视为 external；实施前必须从干净安装推导 production closure，不能假设复制 `dist` 一定完整。
- T3 的 `node-pty`、SQLite 或其他 native binding 必须匹配 Acro bundled Node 的 ABI、macOS 架构与 hardened runtime 签名。
- WKWebView cookie 注入、HttpOnly 属性和进程重启恢复需要真实 App 测试，不能只依赖 URLSession 单测。
- 选择空闲端口后到 sidecar bind 存在极短竞争窗口；失败必须重新选择并重启，不能固定占用一个全局端口。
- T3 sidecar 更新会终止其活跃 Agent/PTY；UI 必须与 Acro daemon 更新边界分开提示。
- 遗留 sidecar 只能在 PID、版本、base-dir、runtime state 和健康探针均匹配时复用或终止；仅凭端口或进程名操作会误伤外部 T3。
- 首版 local-only 会限制远程 Acro 场景；远端兼容模式需要单独设计 HTTP/WS 隧道或在目标主机暴露受认证的 T3 endpoint，不能在本计划中顺手扩张。
- 同一项目可同时被 Acro Agent 和 T3 操作，Git 竞争由用户选择产生；两个模式不得暗中同步或覆盖工作目录。
- 官方包升级可能改变 bootstrap、静态资源路径或 Web 能力探测；版本更新必须走显式回归，不允许自动 latest。
- App 体积会增加；只有实际打包测量后才能决定是否需要压缩或按需下载，首版不预建下载器。
- T3 Connect、Tailscale 和 SSH 等远程入口涉及另一套凭据与生命周期，首版关闭，不能借 loopback 模式意外暴露。
- `pnpm deploy --legacy --prod --no-optional` 产物无法启动：`ffi-rs` 在模块加载阶段需要当前平台的可选包 `@yuuang/ffi-rs-darwin-arm64`。因此不能整批移除 optional dependencies；首版保留完整 production closure，只裁剪可明确识别的非 Darwin `node-pty` 预构建和 source map。
- production closure 的许可证盘点为 MIT 172、Apache-2.0 6、ISC 10、BSD-3-Clause 3、BSD-2-Clause 1、Unlicense 1，以及两个 `@anthropic-ai/claude-agent-sdk*` 包使用 `SEE LICENSE`。后两者的随包 `LICENSE.md` 明确为 Anthropic all-rights-reserved 并受其 Legal Agreements 约束；它们必须作为未修改的独立 T3 运行闭包保留原许可文本和第三方声明，不能描述为 Acro 的 GPL 源代码。
- T3 的 Claude Provider 在 `dist/bin.mjs` 顶层导入 `@anthropic-ai/claude-agent-sdk`，其 Darwin arm64 binary 约 245 MB；删除该 optional package 会破坏启动或 Claude Provider，不能作为无损体积优化。
- `pnpm deploy --legacy` 会在 closure 的 `.pnpm/node_modules/@acro/t3-compat` 留下一个指回源 worktree 的 workspace 自引用 symlink。T3 运行时不使用它，但 `codesign --verify --deep --strict` 会报 `invalid destination for symbolic link in bundle`；打包必须删除该链接并执行整包深度校验。
- pnpm 11 的非 legacy deploy 拒绝未启用 `inject-workspace-packages` 的 workspace；为单个兼容包改变全仓 workspace 注入语义不值得。legacy deploy 可用但会暂时把共享 `node_modules` 标记为 production，所以打包脚本必须在 deploy 后立即执行一次 lockfile 对应的 `CI=true pnpm install` 恢复开发状态。
- 删除 source map 和非 Darwin `node-pty` prebuild 后，实际 ad-hoc `.app` 为 568 MB，其中 T3 closure 400 MB；zip 165 MB、dmg 220 MB。体积主要来自真实 Provider runtime，首版不引入按需下载器。
- 真实 App 中 WKWebView 的辅助功能树显示上游 `T3 Code (Alpha)`、Projects、Search、Add project 和 Settings；说明加载的是 T3 原始 Web UI，不是 Acro 仿制页面。
- 真实生命周期验证中，App 退出后测试 T3 PID `78068` 仍健康；使用同一 state dir 重启 ad-hoc App 后重新附着同一 origin `http://127.0.0.1:58930`。原 Acro terminal daemon PID 在模式切换、退出和重开前后均为 `9671`。
- T3 的 desktop bootstrap grant 只有 24 小时，而 browser session 更长；重开 App 时不能无条件重新交换 bootstrap。WKWebView 现在先把持久 cookie 交给同一 loopback origin 的 `/api/auth/session` 验证，只有无效时才使用 bootstrap token，避免长期运行 sidecar 在 24 小时后误失效。
- 正式签名不能只匹配 `.node`、`spawn-helper` 和执行位：T3 closure 还含两个无执行位的 `t3-resource-monitor` Mach-O 与 `libfff_c.dylib`。签名链已改为遍历 runtime/T3 全部文件并用 `file` 识别 Mach-O 后逐个签名。

## 参考指针

- Acro 蓝图：`.planning/blueprint.md`
- Acro 本地 Runtime：`apps/desktop-macos/Sources/LocalRuntime.swift`
- Acro 打包签名：`apps/desktop-macos/scripts/package-app.sh`
- Acro terminal daemon：`apps/runtime/src/daemon/daemon.ts`
- T3 参考仓库：`.tmp/t3code`，审计 HEAD `ef4ec2ad4b9b08d1aca31d68aea28f0a846ef295`
- T3 CLI：`.tmp/t3code/apps/server/src/cli/server.ts`
- T3 Server 配置：`.tmp/t3code/apps/server/src/cli/config.ts`
- T3 Desktop bootstrap：`.tmp/t3code/packages/contracts/src/desktopBootstrap.ts`
- T3 Desktop backend manager：`.tmp/t3code/apps/desktop/src/backend/DesktopBackendManager.ts`
- T3 认证：`.tmp/t3code/docs/internals/environment-auth.md`
- T3 Provider 架构：`.tmp/t3code/docs/internals/providers.md`
- T3 许可证：`.tmp/t3code/LICENSE`
