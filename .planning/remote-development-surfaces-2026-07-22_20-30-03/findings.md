# 调研与结论：remote-development-surfaces

- 任务 ID：remote-development-surfaces-2026-07-22_20-30-03
- 创建时间：2026-07-22_20-30-03
- 调研方式：仓库源码、现有测试、蓝图、只读参考源码、本机已安装工具与 npm 元数据

## 2026-07-23 Acro 与 Orca 差异复核

复核基线：

- Acro：`a6d6fd46f6ac7bb6b1ccc8a943ce43e6a79c074c`。
- Orca：用户要求更新后，`.tmp/orca` 的 `main/origin/main` 均为 `88b7e69ba115de060a9cc5a354ae3d3f5538166f`。
- 只按用户可独立进入、查看或操作的功能域统计，不按源码目录或文件数量统计。
- 只有 Runtime、协议和客户端入口形成可达闭环时才算完成；只有后端代码记为底座。

28 个用户可感知模块的结论：

| 分类 | 数量 | 结论 |
|---|---:|---|
| 已覆盖或由不同架构覆盖 | 10 | 远端 Runtime、多主机配对、持久终端、分屏布局、移动终端、只读文件/Git/端口、命令面板、设置更新 |
| 当前产品边界内应补齐 | 9 | CLI、浏览器表面、浏览器语义控制、iOS Simulator、Computer Use、移动 Workspace、Agent 状态/审批、通知未读、诊断兼容 |
| Acro 内部规格冲突 | 1 | Workspace 是否必须引用 Project |
| 明确不复制 | 6 | Worktree/Git 写入、内置编辑器、账号/用量/Native Chat、自动化/多 Agent、任务平台、插件/Provider 管理 |
| 可选扩展 | 2 | 快捷命令/语音；Windows/Linux 桌面、Android 和完整多语言 |

核心判断：Acro 与 Orca 有 18 个模块差异，但只有 9 个是当前 Acro 核心欠账。若用户仍要求显式 Project 归属，核心欠账变为 10 个。

### 28 模块总账

| # | 用户能力 | Acro 当前事实 | 分类 | 本计划处理 |
|---:|---|---|---|---|
| 1 | 远端 Runtime 持有真实状态 | Runtime + 独立 terminal daemon | 已覆盖 | 保持 |
| 2 | 配对、多入口、多主机、远程安装 | E2EE、RuntimeHub、acro ssh | 不同实现覆盖 | 保持 |
| 3 | Workspace 与 Project 归属 | 文档要求 Project，代码明确删除 | 规格冲突 | 阶段 -1 裁决 |
| 4 | 持久终端、快照、滚动历史、重连 | Desktop/Mobile/CLI 已接入 | 已覆盖 | 回归保护 |
| 5 | 标签、分屏、布局、快捷键、外观 | 原生 Ghostty + Bonsplit | 已覆盖 | 扩展到混合 Surface |
| 6 | 完整 CLI 控制面 | 只有 pair/ssh/endpoints/sessions/run/attach | 核心缺口 | 阶段 7 |
| 7 | 移动终端和跨设备输入权 | xterm WebView + 显式接管 | 已覆盖 | 回归保护 |
| 8 | 文件浏览、搜索和预览 | Desktop 只读文本/图片 | 按边界覆盖 | 不增加写入 |
| 9 | 内置编辑器、文件写入、丰富预览 | 无编辑器；丰富预览有限 | 不复制 | 只读 Markdown/PDF 可另行确认 |
| 10 | Git 状态与 diff | Desktop 只读 | 按边界覆盖 | 不增加 Git 写入 |
| 11 | Worktree、stage、commit、PR、diff 评论 | 无 | 不复制 | 排除 |
| 12 | 端口发现 | ports.list + Desktop 面板 | 已覆盖 | CLI 补查询入口 |
| 13 | Browser 可见 Surface | Runtime 有底座，正式入口断裂 | 核心缺口 | 阶段 2、3、6 |
| 14 | Browser 语义控制与 Design Mode | 只有坐标输入，没有 snapshot/ref | 核心缺口 | 阶段 3、7；完整 Design Mode 不单独承诺 |
| 15 | Simulator / Emulator | Mobile 可 boot/view，约 1fps，无输入 | 核心缺口 | 阶段 4、6、7 |
| 16 | Computer Use | Runtime/helper 有底座，客户端零入口 | 核心缺口 | 阶段 5、6、7 |
| 17 | Mobile Workspace 工作台 | 主页平铺全局 Session | 核心缺口 | 阶段 2 |
| 18 | 通用 Agent 状态、提问和审批 | 无协议与入口 | 核心缺口 | 阶段 7A |
| 19 | 通知、未读和断线补齐 | 无持久通知；事件无回放 | 核心缺口 | 阶段 7B |
| 20 | Agent 账号、用量、历史、Native Chat | 无 | 不复制 | 排除供应商专用控制面 |
| 21 | 定时自动化、多 Agent 编排、任务 DAG | 无 | 不复制 | 排除 |
| 22 | GitHub、Linear、Jira 等任务源 | 无 | 不复制 | 排除 |
| 23 | 快捷命令、语音输入 | 无 | 可选扩展 | 不进入核心验收 |
| 24 | Skills、Provider Profile、插件管理 | 无产品管理面 | 不复制 | 仅随 CLI 打包必要 skills |
| 25 | Quick Open / 命令面板 | 命令、Workspace、Session 已可搜 | 已覆盖但较浅 | 保持最小范围 |
| 26 | 设置、快捷键、主题、更新 | Desktop 已交付 | 已覆盖 | 回归保护 |
| 27 | 诊断、引导、协议兼容 | 只有重连横幅 | 核心缺口 | 阶段 1、7C |
| 28 | Windows/Linux Desktop、Android、完整多语言 | Runtime 有 Linux/WSL，客户端仍 Apple 优先 | 可选扩展 | 不进入核心验收 |

### 当前 Acro 的可验证覆盖

- 协议定义 53 个 RPC 和 8 个声明事件；53 个 RPC 都有 Runtime 处理器。
- 37 个 RPC 已有 Desktop、Mobile 或 CLI 正式调用；16 个没有完整客户端入口。
- 16 个无入口 RPC 由 6 个 Browser 管理方法、simulator.shutdown 和 9 个 Computer Use 方法组成。
- Desktop 工作台当前只承载终端窗格；右侧栏只有上下文、文件、Git 和端口。
- Mobile 主页只列全局 Session 和 Simulator。Browser Surface 组件存在，但没有 browser.open/list 产生可达 browserId。
- CLI 当前只有 pair、ssh、endpoints、sessions、run 和 attach。

### Orca 当前对照能力

- Orca README 明确交付移动伴侣、并行 Worktree、终端分屏、Design Mode、GitHub/Linear、SSH Worktree、diff 评论、编辑器和 CLI。
- Orca CLI specs 已覆盖 project、file、automation、browser、orchestration、computer、diagnostics、environment、Linear、VM、emulator 和 skills。
- Browser CLI 支持 accessibility snapshot、ref click、fill、wait、eval、drag、upload 等语义操作。
- Computer Use CLI 支持应用/窗口枚举、accessibility snapshot、元素动作、滚动、拖拽、输入、快捷键和 set-value。
- Emulator CLI 同时覆盖 iOS 与 Android，并提供 tap、gesture、install、launch、permissions、AX 和 logcat。
- Orca Mobile 已有 Source Control、Agent History、Changes、PR、通知和故障排查路由。

这些 Orca 能力只用于判断差异。违反 Acro 已确认边界的 Worktree、Git 写入、编辑器、任务平台和供应商编排不能自动转化为 Acro 需求。

## Project / Workspace 规格冲突

当前事实互相矛盾：

- AGENTS.md 与蓝图描述 Workspace 引用用户加入的 Project。
- `packages/protocol/src/models.ts` 明确写着 Workspace 是纯分组与界面容器，只持 sessionIds 和 layout。
- `apps/runtime/src/workspaces.ts` 创建 Workspace 时不保存路径或项目。
- RPC 方法表没有 `project.*`。
- Git 历史已有 `feat!: drop the project entity, inherit terminal cwd from established fact`，说明删除不是遗漏，而是一次显式架构变更。

Planning 不能在这两套契约之间暗自选择。阶段 -1 必须让用户确认唯一契约：保持纯 Workspace 容器时同步修正文档；恢复 Project 时补齐对外数据模型、迁移已有 Workspace，并同步协议、鉴权、codegen 和全部客户端。不得只在某个客户端补一个项目选择器。

## Agent 状态与通知的根因设计

Acro 不能复制 Orca 的供应商深度编排，也不能解析普通 PTY 输出猜状态。最小根本方案是：

1. 供应商适配器在 Agent 已有 hook 中生成带 Acro namespace 的版本化 OSC 消息。
2. terminal daemon 只解析这类显式消息，并把通用 AgentActivity/AgentRequest 绑定到 sessionId。
3. Runtime 保存当前状态和未解决问题；客户端只显示通用状态并定位终端。
4. 审批选项最终仍通过现有终端输入链路写入 PTY，继续服从 session.claimFocus。
5. 没有适配器的 Agent 安全降级成普通终端，不产生推测状态。

在线事件无法满足 iOS 后台与断线通知。Runtime 必须持久化通知和按设备未读；Push 只能携带 opaque notificationId，真实内容在 App 重连后经 E2EE 拉取。

## 需求事实

- Acro 的真实进程、浏览器、Simulator 和系统权限都在 Mac mini。客户端只显示、输入和控制。
- 蓝图已经定义 Terminal、Browser、Simulator、Computer Use 四种 Surface，但桌面工作台当前仍只保存终端 sessionIds。
- 用户要求完整规划，不要求本轮实现。
- 浏览器需要同时服务两类消费者：人通过远程画面控制，Agent 通过结构化浏览器自动化控制。
- Simulator 需要实时画面和输入。单纯提高 simctl screenshot 轮询频率不是根本方案。
- Computer Use 必须提供稳定观察和动作语义，不能继续让 Runtime 猜 helper 的未知 JSON。
- 多设备观察和单一输入控制权是跨领域要求，不是 Browser 或 Terminal 的局部功能。

## 真实调用链

### Browser

1. 协议和 Runtime 已实现 browser.open/list/claimControl/controlList/navigate/attach/detach/input/close。
2. apps/runtime/src/index.ts 把请求交给 BrowserManager。
3. apps/runtime/src/browser.ts 使用 playwright-core 启动持久 Chromium context，在 Mac mini 创建 Page。
4. browser.attach 返回连接内 channel，并启动 Page.startScreencast。
5. CDP Page.screencastFrame 产生 JPEG。Runtime 经 FRAME_BROWSER 和 E2EE WebSocket 发给订阅客户端。
6. Mobile 只有在已知 browserId 时才能 attach 和发送坐标点击；Desktop 与 CLI 没有 Browser 正式入口。
7. 当前三个正式客户端都没有 browser.open/list/claimControl/controlList/navigate/close 调用，因此用户无法创建或选择 browserId。

当前缺口：

- Browser Surface 没有进入桌面 Workspace 布局。
- Agent 没有稳定方式选择并操作指定 browserId。
- agent-browser 未随 Acro 固定版本打包。
- 当前帧不携带 codec、尺寸变化和旋转元数据。
- CDP screencast 总是立即 ack，发送层没有按连接缓冲执行背压。

### Simulator

1. 协议和 Runtime 已实现 simulator.list、boot、shutdown、attach、detach。
2. apps/runtime/src/simulator.ts 通过 xcrun simctl 管理设备。
3. simulator.attach 启动 simctl io screenshot 轮询。
4. 每次截图生成 PNG，并经 FRAME_SIM 与 E2EE WebSocket 发送。
5. apps/mobile/App.tsx 把字节转成 base64 data URI 后交给 React Native Image。
6. 正式客户端只有 Mobile 调用 list、boot、attach 和 detach；shutdown 没有 Desktop、Mobile 或 CLI 入口。

当前缺口：

- 截图轮询约 1fps，不能承担交互。
- 没有触摸、滑动、输入和硬件键。
- 没有 Simulator 控制权。
- attach 只返回 channel，不返回稳定尺寸和旋转。
- base64 data URI 会复制数据并占用 JS 线程，不适合持续画面。

### Computer Use

1. 协议和 Runtime 已实现 claimControl、controlOwner、permissions、capture、windows、click、type、key 和 activate。
2. apps/runtime/src/index.ts 校验 Computer control owner。
3. apps/runtime/src/computer.ts 通过 Unix socket 向 helper 发送 NDJSON。
4. apps/helper-macos/Sources/main.swift 使用 CoreGraphics 和 Accessibility 执行截图与动作。
5. capture 把 PNG 作为 base64 放进 JSON RPC 返回。
6. Desktop、Mobile 和 CLI 对全部 computer.* 都没有正式调用，当前只有测试与 E2E 脚本能触达底座。

当前缺口：

- helper 没有版本化 handshake。
- windows 返回 unknown 数组，Runtime 没有稳定 schema。
- 没有 snapshotId、元素 ref、缓存生命周期和可验证动作。
- 截图经本机 base64 JSON 再经远程 JSON，内存和协议开销过大。
- helper 错误是字符串，客户端无法稳定处理权限、过期引用和无效状态。

### RPC 可达性账本

扫描范围：`apps/desktop-macos/Sources`、`apps/mobile`、`apps/cli/src`，排除测试、构建产物和依赖目录。当前 53 个 RPC 中有 16 个没有正式客户端入口：

| 领域 | 无入口方法 | 计划补齐阶段 |
|---|---|---|
| Browser | browser.open、browser.list、browser.claimControl、browser.controlList、browser.navigate、browser.close | 阶段 2、3、6、7 |
| Simulator | simulator.shutdown | 阶段 2、4、6、7 |
| Computer Use | computer.claimControl、controlOwner、permissions、capture、windows、click、type、key、activate | 阶段 2、5、6、7 |

自动化脚本能调用 RPC 不等于用户入口。实现完成时，每个目标方法必须至少存在一个 Desktop、Mobile 或 CLI 可达路径，并有对应 UI/CLI 测试。方法总数和无入口列表必须在每次协议变更后重新生成，不能把本次数字永久写死成守门条件。

### Desktop Workspace

1. apps/desktop-macos/Sources/WorkbenchLayoutState.swift 的 PaneTabGroup 保存 sessionIds 与 selectedSessionId。
2. WorkbenchModel 与 TerminalPanesView 用 sessionId 做切换、分屏、拖拽和关闭。
3. workspace.setLayout 把整棵布局编码为 opaque JSON 交给服务端保存和广播。

结论：

- 服务端无需理解布局迁移。
- 根本修改点是客户端布局身份模型。把 sessionIds 机械扩充为多组数组会继续复制操作逻辑。
- SurfaceRef 只需统一 kind 与 id；终端、浏览器、Simulator、Computer Use 的业务 RPC 不需要合并。

### Mobile

1. apps/mobile/src/client.ts 解密二进制帧并用 packages/protocol 的 decodeFrame 解码。
2. apps/mobile/App.tsx 的 SurfaceScreen 订阅 Browser 或 Simulator channel。
3. 每个动画帧窗口只保留最新字节，这一丢帧方向正确。
4. flush 时仍把字节转为 base64 data URI，随后交给 Image 解码。

结论：

- 最新帧覆盖可以保留。
- 正式实现必须把二进制解码移到原生层，不能只优化 JavaScript base64 函数。

## 调研结论

### 协议

- packages/protocol/src/rpc.ts 已经是方法和事件唯一真源。
- packages/protocol/src/frames.ts 已经区分终端、浏览器和 Simulator 二进制帧。
- 现有 RpcError.code 是任意 string，需要收紧为稳定集合。
- 现有 attach channel 是连接内编号，可以继续复用，不需要全局流 ID。
- 最小兼容方式是 attach 参数协商 streamVersion。旧客户端不传时继续收到旧帧。

### Runtime

- apps/runtime/src/index.ts 已有 ExclusiveRunner，可用于同一 Surface 的控制权、关闭和生命周期串行化。
- Browser 与 Computer 已有设备控制权。Simulator 需要补齐相同语义。
- 设备断开时已有 Browser 和 Computer 释放逻辑，可抽取共享规则，但不需要 provider 基类。
- 持久终端 daemon 与 Runtime 版本可能不同。新终端环境字段需要旧 daemon 兼容，不能假设 daemon 已重启。
- apps/runtime/scripts/e2e.ts 已覆盖多设备 attach、focus 接管、重连和并发，是新增 Surface 回归的高价值入口。

### 现有 CLI

- apps/cli 已经存在，不需要新建应用。
- apps/cli/src/cli.ts 已实现 pair、ssh、endpoints、sessions、run 和 attach。
- apps/cli/src/client.ts 已复用 packages/protocol、~/.acro/client.json、E2EE WebSocket 和流控。
- apps/cli/src/args.ts 已集中处理参数边界，并有注入与歧义测试。
- browser、emulator 和 computer 应作为现有命令树的子命令扩展，不能再建第二套客户端、配置或连接层。

### Browser 参考

- Orca 的 agent-browser-bridge.ts 证明 agent-browser 可以通过 CDP 控制已有页面。
- Orca 的 cdp-ws-proxy.ts 处理目标隔离、CDP 发现和事件转发，Acro 只需要与 browserId 隔离直接相关的部分。
- Orca Browser 代码还包含 Electron webContents、证书、cookie 导入、下载和本地窗口能力，这些不适合 Acro 当前远程 Chromium 架构。
- cmux 的 CmuxBrowser 与 CmuxMobileBrowser 是本地 WKWebView 状态和视口模型。它们可参考布局与尺寸测试，但不能作为 Acro Browser Runtime。

### Simulator 参考

- Orca 的 ios-emulator-backend.ts 使用 serve-sim 启动 detached stream，并等待 endpoint 就绪。
- mjpeg-frame-parser.ts 与 mjpeg-frame-stream.ts 提供跨 chunk MJPEG 解析参考。
- emulator-gesture-sender.ts 提供 serve-sim 输入映射参考。
- serve-sim-runtime-materializer.ts 说明签名 App 内的 DYLD helper 需要物化到包外版本目录。
- Orca 同时有 Android 和统一 backend 抽象。Acro 当前只需要 iOS，不应移植 Android 或多 backend 框架。

### Computer Use 参考

- Orca 的 native/computer-use-macos provider 使用版本化 handshake、observe、snapshotId、缓存和 action。
- macos-native-provider-client、contract、socket 与权限文件提供 Runtime 对接边界。
- Orca 还有 sidecar、Linux、Windows 与通用 provider lifecycle。Acro 当前不需要这些层。
- 现有 Acro HelperClient 已经具备 Unix socket、队列上限、deadline、取消和重连，应保留并替换消息契约。

### 许可证与工具版本

- Acro 根目录已有 GPL-3.0-or-later LICENSE。
- Orca 是 MIT。移植 macOS provider 或 bridge 代码时必须保留版权声明并记录取用文件。
- cmux 是 GPL-3.0，与 Acro 兼容；本计划不复制其本地浏览器实现。
- agent-browser 0.31.1 的 npm license 是 Apache-2.0。
- serve-sim 0.1.40 的 npm license 是 Apache-2.0。
- 实现时必须固定精确版本和完整性校验，不沿用 Orca 的浮动范围。

### 本机事实

- 本机 cmux 版本为 0.64.20。
- 本机 agent-browser 版本为 0.31.1。
- Orca CLI 已安装，但 Orca Runtime 未运行。
- 这些本机安装只能用于调研和真实验证，发布包不能依赖用户预装。

## 技术决策

| 决策 | 证据 |
|---|---|
| SurfaceRef 只统一 kind 与 id | 桌面布局操作需要共同身份，领域生命周期并不相同 |
| server.info 是连接后的第一项能力探测 | 蓝图已要求按平台隐藏，当前客户端没有可靠平台事实 |
| attach 用 streamVersion 做兼容 | 现有领域 RPC 和旧帧可以原样保留 |
| 版本 2 帧携带 codec、尺寸、旋转和 seq | 当前 Mobile 依赖帧类型猜 mime，Simulator 又缺尺寸 |
| 使用最新帧覆盖和发送缓冲阈值 | 远程控制需要低延迟，不需要逐帧播放 |
| Browser UI 与 Agent 自动化共用同一 Page | 用户与 Agent 必须看到同一服务端真实状态 |
| agent-browser 通过短期回环 CDP lease 工作 | 不重写自动化，同时不把原始 CDP 暴露给 LAN |
| serve-sim 只向 Runtime 提供本机流 | 远程设备无法访问 Mac mini 的 localhost |
| simctl 继续管理设备生命周期 | serve-sim 解决流和输入，不替代成熟设备管理 |
| 移植 Orca macOS provider，不移植 provider 框架 | 当前平台边界明确，额外抽象没有第二实现 |
| 移动端增加原生二进制图像 Surface | data URI 每帧复制不适合持续画面 |
| CLI 与 skills 同包同版本 | 本机独立文档会和命令漂移 |
| 扩展现有 apps/cli | 已有配对、配置、连接、背压和参数校验，重复实现会制造协议漂移 |
| CLI 继续使用 AcroClient 和 client.json | 当前连接层已满足认证、E2EE 与多入口，不需要新增本机 socket |
| 布局移除与领域终止分开 | 现有 Terminal 关闭会终止 PTY，但 Simulator 和 Computer Use 关闭只应停止观看 |
| 不在终端环境注入 token | Agent 需要上下文，不需要长期凭证 |

## 风险与边界

- CDP 是高权限接口。必须只监听回环地址、限制到一个 browserId、设置 lease 到期和进程退出清理。
- agent-browser 与 Chromium 版本存在兼容面。发布包必须用真实页面执行核心命令自检。
- serve-sim 使用 DYLD 注入与辅助二进制。打包、签名、隔离属性和物化路径是功能的一部分，不是发布尾项。
- Simulator 画面旋转会改变尺寸。帧必须携带旋转和真实像素尺寸，客户端不能缓存 attach 初始值。
- Computer Use 权限与签名身份绑定。helper bundle identifier 或签名主体变化会让已有授权失效。
- Accessibility 树和截图可能含敏感信息。它们只能在用户已授权的 E2EE 会话与本机 CLI 中流转，不写普通日志。
- 多设备控制权释放不能只依赖显式 detach。连接关闭、设备撤销和 Surface 关闭都必须清理。
- 旧 Runtime 的 method_not_found 是正常兼容路径，不能显示成服务端崩溃。
- Browser Surface 当前不跨 Runtime 进程重启。客户端必须清理失效引用，不能显示空白旧标签。
- Agent OSC 可以被同一 PTY 内其他进程伪造，因此它只能影响状态展示和会话定位，不能直接授予权限或执行命令。必须限制版本、长度、频率和 schema。
- iOS 后台可靠通知依赖 APNs/Expo Push 和发布凭证。推送不可用时必须保留 Runtime 通知，不能把第三方交付当作唯一真相源。
- 通知记录和 AgentRequest 可能含敏感摘要。Runtime 必须限制保留量，推送和普通日志不得包含正文。
- Workspace / Project 契约未裁决前，移动工作台的数据模型和鉴权范围都不稳定，阶段 0 与阶段 2 不得开始。
- 新 worktree 不包含被忽略的 .tmp 参考目录。实现者必须从主 checkout 只读参考，不能把参考源码误加进 Git。
- 移动端实现前必须遵守 apps/mobile/AGENTS.md，读取 Expo 57 精确版本文档。

## 已验证基线

调研阶段已经验证以下现有基线：

| 检查 | 结果 |
|---|---|
| Runtime tests | 101 项通过 |
| Protocol tests | 11 项通过 |
| Mobile tests | 5 项通过 |
| Runtime typecheck | 通过 |
| Protocol typecheck | 通过 |
| Swift helper build | 通过 |

这些结果只证明规划前基线，不代表计划中的功能已实现。

## 参考指针

- .planning/blueprint.md
- packages/protocol/src/rpc.ts
- packages/protocol/src/frames.ts
- packages/protocol/src/models.ts
- apps/runtime/src/index.ts
- apps/runtime/src/ws.ts
- apps/runtime/src/browser.ts
- apps/runtime/src/simulator.ts
- apps/runtime/src/computer.ts
- apps/runtime/src/daemon/env.ts
- apps/cli/src/cli.ts
- apps/cli/src/args.ts
- apps/cli/src/client.ts
- apps/helper-macos/Sources/main.swift
- apps/desktop-macos/Sources/WorkbenchLayoutState.swift
- apps/desktop-macos/Sources/RuntimeConnection.swift
- apps/desktop-macos/Sources/WorkbenchModel.swift
- apps/desktop-macos/Sources/TerminalPanesView.swift
- apps/mobile/App.tsx
- apps/mobile/src/client.ts
- apps/mobile/src/surface.ts
- .tmp/orca/src/main/browser/agent-browser-bridge.ts
- .tmp/orca/src/main/browser/cdp-ws-proxy.ts
- .tmp/orca/src/main/emulator/backends/ios-emulator-backend.ts
- .tmp/orca/src/main/emulator/mjpeg-frame-parser.ts
- .tmp/orca/src/main/emulator/emulator-gesture-sender.ts
- .tmp/orca/src/main/emulator/serve-sim-runtime-materializer.ts
- .tmp/orca/src/main/computer/macos-native-provider-client.ts
- .tmp/orca/native/computer-use-macos
- .tmp/orca/README.md
- .tmp/orca/src/cli/specs/index.ts
- .tmp/orca/src/cli/specs/browser-basic.ts
- .tmp/orca/src/cli/specs/computer.ts
- .tmp/orca/src/cli/specs/emulator.ts
- .tmp/orca/mobile/app/h/_layout.tsx
- .tmp/orca/mobile/app/troubleshoot.tsx
- .tmp/cmux/Packages/macOS/CmuxBrowser
- .tmp/cmux/Packages/iOS/CmuxMobileBrowser
