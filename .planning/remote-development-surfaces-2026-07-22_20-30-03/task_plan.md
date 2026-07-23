# 任务计划：remote-development-surfaces

- 任务 ID：remote-development-surfaces-2026-07-22_20-30-03
- 创建时间：2026-07-22_20-30-03
- 本轮交付：完整规划，不实现产品代码
- 补充基线：2026-07-23 对比 Acro `a6d6fd4` 与 Orca `88b7e69b` 后补齐移动工作台、Agent 状态、通知和诊断范围

## 目标

把终端、浏览器、iOS Simulator 和 macOS Computer Use 纳入同一套远程 Workspace 工作台。Runtime 继续持有真实进程、画面、控制状态、Agent 活动和通知记录。桌面端与移动端只负责显示、输入和明确授权。Agent 在 Workspace 终端中通过随 Acro 发布的 CLI 和 skills 操作这些能力。

完成实现后，系统必须满足以下结果：

1. Workspace 布局可以同时保存四种 Surface，并能从现有只保存终端 sessionIds 的布局无损迁移。
2. 客户端连接后通过 server.info 识别服务端平台、协议版本和可用能力，不向用户展示服务端不支持的入口。
3. 浏览器继续由 Runtime 的 Chromium 提供画面和输入，同时由固定版本 agent-browser 提供 Agent 自动化能力。
4. iOS Simulator 使用 serve-sim 提供实时画面和输入；simctl 负责设备生命周期以及 Apple 原生的安装、启动和日志能力。
5. Computer Use 使用移植后的 Orca macOS provider 提供可验证的观察和动作，不再依赖当前简化 helper 契约。
6. 所有远程画面都经过现有 E2EE WebSocket 转发。客户端不会收到只能在 Mac mini 本机访问的 localhost 地址。
7. 多设备可以同时观看同一 Surface，但同一时刻只有一个设备可以输入。断线、重连和显式接管都遵循一致规则。
8. 桌面端和移动端只渲染最新画面。慢客户端不会把延迟持续堆积到服务端或 UI。
9. 移动端按 Server → Workspace → Surface 导航，可以创建或选择 Workspace，并按阶段 -1 裁决后的 Project/cwd 契约创建终端，不再把所有 Session 平铺为主页。
10. Agent 通过显式适配器上报 working、needs_user、done 和 error 等通用状态；Runtime 不解析普通 PTY 文本，也不绑定某个 Agent 供应商。
11. Agent 提问或需要审批时，移动端可以定位到对应会话、查看结构化提示并通过现有终端输入链路作答；未知 Agent 仍安全降级为普通终端。
12. Runtime 保存可恢复的通知与未读状态。iOS 后台推送只携带不敏感的唤醒信息，详细内容在客户端重连后通过 E2EE 获取。
13. 用户可以查看服务器版本、能力、依赖、权限、连接入口和协议兼容结果，并获得可执行的修复提示。
14. 本计划新增或补齐的每个 RPC 都必须绑定至少一个 Desktop、Mobile 或 CLI 可达入口；测试脚本直接调用不能替代用户入口。

## 范围

- 协议：SurfaceRef、能力协商、稳定错误码、控制权模型、版本化画面帧和 Swift codegen。
- Runtime：浏览器、Simulator、Computer Use 的生命周期、画面转发、输入、背压、控制权和断线清理。
- Workspace：桌面布局从终端 ID 列表迁移为 Surface 引用列表。
- 桌面端：四种 Surface 的列表、打开、分屏、切换、关闭、画面显示、输入和控制权提示。
- 移动端：能力隐藏、浏览器与 Simulator 控制、Computer Use 入口、原生二进制画面解码。
- 移动工作台：多服务器、Workspace/分组导航、工作目录选择、Surface 列表和会话创建。
- Agent 状态：供应商外置适配器、通用状态/提问模型、会话定位和审批输入。
- 通知：Runtime 持久记录、按设备未读、移动端本地通知和可选的最小化后台推送。
- 诊断：server.info 展示、协议兼容闸门、连接日志、依赖与权限检查、可复制诊断报告。
- Agent 工具：扩展现有 acro CLI，覆盖 Workspace、只读文件/Git/端口、browser、emulator、computer 和 doctor，并与 skills 同版本发布。
- 打包：固定工具版本、第三方许可证、嵌套可执行文件权限、签名、公证和运行时物化。
- 验证：协议、Runtime、Swift、移动端、真实 Mac mini、真实远程设备和发布包。

## 非目标

- 不实现 Android Emulator、scrcpy 或 Android Computer Use。
- 不移植 Orca 的 Linux、Windows provider 框架。
- 不在 Acro 重写 agent-browser 的 snapshot、ref、wait、profile、表单和网络工具。
- 不复制 cmux 的本地 WKWebView 浏览器架构。Acro 显示的是 Mac mini 上的远程 Chromium。
- 不创建统一包办所有领域动作的 surface.open、surface.input 或 provider 工厂。
- 不把浏览器移入终端 daemon。Runtime 重启后浏览器引用失效，客户端按服务端真实列表清理；浏览器 profile 继续持久化。
- 不改变 Acro 的 Git、分支、worktree 或提交边界。
- 不增加 Worktree 管理、Git 写入、内置编辑器、PR 评审、任务平台或插件市场。
- 不实现 Agent 账号切换、用量追踪、供应商专用 Native Chat 或多 Agent fan-out。
- 不通过关键词、正则或 TUI 画面启发式猜测 Agent 状态。
- 不把敏感问题正文、仓库路径、终端内容或设备 token 发送给推送服务。
- 不自研穿透、媒体服务器、视频协议或新的加密层。
- 不新建第二套 CLI、连接客户端或配置格式。直接扩展现有 apps/cli。
- 不在本轮规划交付中实现、发版或热替换本机 dev 实例。

## 关键约束

- packages/protocol 的 zod schema 是协议唯一真源。Swift 类型只由 codegen 生成。
- 服务端是会话、Surface 存活状态、控制权和序号的唯一真相源。
- 客户端断开只能释放该设备的订阅和控制权，不能关闭服务端 Surface。
- 所有公网链路继续使用现有 X25519、HKDF-SHA256 和 ChaCha20-Poly1305 E2EE。
- 本机 CDP、serve-sim 和 helper socket 只监听回环地址或 Unix socket，不作为远程客户端接口。
- 输入、粘贴、文件路径、URL、元素引用和 helper 消息都属于信任边界，必须限制长度并校验状态。
- Computer Use 继续依赖 macOS Accessibility 与 Screen Recording 权限，并保持稳定签名身份，避免每次升级重置 TCC 授权。
- Runtime 在 Linux 或 WSL 上必须继续提供终端、文件、Git 和端口能力。macOS 专属能力通过 server.info 隐藏。
- 实现移动端代码前，必须阅读 Expo 57 的精确版本文档。
- 只引入已确认需要的依赖。agent-browser 和 serve-sim 使用固定版本，不使用浮动版本。
- 参考目录 .tmp/orca 与 .tmp/cmux 只读。取用代码时保留原项目版权与许可证说明。
- Workspace 与 Project 的产品契约当前存在冲突：协议代码把 Workspace 定义为不持项目的界面容器，AGENTS.md 与蓝图仍要求 Project 引用。这属于架构与对外数据模型决策，planning 不替用户选择；阶段 -1 未完成前不得进入协议或移动工作台实现。
- Agent 状态只能来自显式适配器生成的受限消息。消息只表达状态、问题和推荐回答文本，不授予文件、Git、Shell 或系统权限。
- 通知记录由 Runtime 持有。设备撤销后必须删除其推送 token，并停止向该设备发送通知。
- 每次协议变更都重新生成 RPC 可达性账本。方法数量和无入口数量是当前证据，不写成永远不变的常量。

## 核心协议设计

### Surface 身份

协议新增最小 SurfaceRef：

- kind：terminal、browser、simulator、computer。
- id：终端使用 session UUID，浏览器使用 browser UUID，Simulator 使用 UDID，Computer Use 使用固定值 desktop。

协议只统一身份、控制权和画面元数据。现有 session、browser、simulator、computer 领域 RPC 继续保留，避免把不同生命周期塞进一个大分支。

Workspace 布局升级为版本 2：

- PaneTabGroup.sessionIds 改为 surfaces。
- selectedSessionId 改为 selectedSurfaceKey。
- Surface key 由 kind 与 id 共同构成，避免不同领域 ID 碰撞。
- 解码版本 1 时，把每个 sessionId 转成 terminal SurfaceRef。
- 服务端继续把布局当 opaque JSON 保存，不承担客户端布局迁移。
- 客户端第一次保存后只写版本 2；无效或已消失引用按各领域 list 结果清理。

### 能力协商

新增 server.info，返回：

- serverId、runtimeVersion、protocolVersion、platform、arch。
- terminal、browser、simulator、computer 能力。
- 每项能力包含 available；不可用时返回稳定 reasonCode。浏览器另报 stream 与 automation，Simulator 另报 stream 与 input，Computer Use 另报 providerProtocolVersion。

新客户端在连接与重连后读取 server.info。旧 Runtime 不支持该方法时进入 legacy 模式：终端直接可用；其他领域通过现有 list 或 permissions RPC 做一次安全探测，method_not_found 或 unsupported 时隐藏入口。

### 稳定错误码

协议把 RpcError.code 收紧为稳定集合：

- method_not_found
- invalid_request
- not_found
- unsupported
- dependency_unavailable
- permission_denied
- control_required
- control_conflict
- busy
- limit_reached
- timeout
- cancelled
- invalid_state
- internal

Runtime 在统一 RPC 边界映射领域错误。helper 和 CLI 返回同一语义。客户端只按 code 决定 UI，message 只用于用户说明和日志。

### 版本化画面帧

保留现有 FRAME_BROWSER 和 FRAME_SIM 供旧客户端使用。领域 attach RPC 增加可选 streamVersion；缺省值为 1，新客户端请求 2。

版本 2 新增通用画面帧，头部包含：

- frame version
- channel
- seq
- codec：jpeg 或 png
- pixel width 与 height
- rotation：0、90、180、270

本阶段只传完整 JPEG 或 PNG，不引入 H.264。每条订阅只保留尚未发送的最新帧。WebSocket 缓冲超过阈值时丢弃中间帧，序号允许跳跃。浏览器及时确认 CDP screencast 帧；Simulator 解析器丢弃旧 JPEG；Computer Use 在上一帧完成前不发起下一次观察。

### 控制权

复用现有 Session focus、Browser control 和 Computer control 规则，并为 Simulator 增加同等控制权：

- 打开或启动 Surface 的设备默认获得控制权。
- 其他设备默认只读。
- force=false 不抢占其他设备。
- force=true 只用于用户明确接管。
- 同一设备重连可以恢复自己的控制权。
- 设备所有连接都断开后释放控制权。
- 执行领域终止操作前，在同一领域串行器内校验控制权和存活状态。

协议共享 ControlOwner 模型，但保留各领域 claim 与查询 RPC。

### Agent 活动与提问

协议新增最小通用模型，不镜像 Codex、Claude 或其他供应商的内部事件：

- AgentActivity：sessionId、state、summary、updatedAt。
- state：idle、working、needs_user、done、error。
- AgentRequest：requestId、sessionId、prompt、choices、answerText、createdAt、resolvedAt。
- choices 只保存展示文本和要写入终端的 answerText，不执行任意命令。

Agent 适配器通过受限 OSC 消息把状态写入当前 PTY。terminal daemon 只解析带 Acro namespace、版本号、长度上限和 schema 的显式消息；普通终端输出保持不透明。Runtime 把状态绑定到 sessionId，并广播 agent.activityChanged 与 agent.requestChanged。

用户回答时，客户端先按现有 session.claimFocus 规则取得输入权，再把 choice.answerText 作为普通终端输入发送。Acro 不调用供应商私有审批 API。没有适配器的 Agent 只显示终端，不产生虚假状态。

### 通知与未读

Runtime 新增 NotificationRecord：

- id、kind、serverId、workspaceId、sessionId、createdAt、readDeviceIds。
- kind 首期只包含 needs_user、done、error、connection_problem。
- notification.list 支持按游标拉取；notification.markRead 按设备记录已读。
- device.setPushToken 只允许当前设备登记或清除自己的 token。

前台连接直接收 E2EE 事件。iOS 后台可选用 Expo Push API 发送固定标题和 opaque notificationId；App 被唤醒后重新连接 Runtime，再读取真实内容。没有推送 token 或推送服务不可达时，通知仍保存在 Runtime，前台恢复后可见。

### Workspace 与 Project 决策门

当前代码事实是 Workspace 只持 sessionIds 与 layout，创建终端通过 cwd 或 inheritCwdFrom 确定目录；AGENTS.md 与蓝图则要求 Workspace 引用 Project。两套契约不能同时成立。

阶段 -1 必须由用户明确选择并落盘唯一契约：

- 保持纯 Workspace 容器：同步修正 AGENTS.md 与蓝图，删除 Project Registry、Project reference、项目归属鉴权和“加入项目”流程；移动端通过目录选择器或已有会话 cwd 创建终端。
- 恢复 Project 契约：新增 Project schema、registry、RPC、Workspace 引用、存储迁移、项目选择、归属鉴权、Swift codegen 和全部客户端入口。

未裁决前不得在移动端单独伪造 Project，也不得修改现有 Workspace 持久化格式。

## 修改路径

| 区域 | 主要路径 | 计划修改 |
|---|---|---|
| 协议 | packages/protocol/src/models.ts、rpc.ts、frames.ts、index.ts | SurfaceRef、能力、错误码、控制权、画面帧 |
| Swift codegen | packages/protocol/scripts/codegen-swift.ts、apps/desktop-macos/Sources/Generated/ProtocolModels.swift | 生成新协议类型，不手写镜像 |
| Runtime 总线 | apps/runtime/src/index.ts、ws.ts、exclusive.ts | server.info、错误映射、订阅、背压、断线清理 |
| Browser | apps/runtime/src/browser.ts 及对应测试 | Chromium 生命周期、CDP lease、agent-browser、画面元数据 |
| Simulator | apps/runtime/src/simulator.ts 及对应测试 | serve-sim 进程、MJPEG、输入、控制权 |
| Computer Use | apps/runtime/src/computer.ts、apps/helper-macos | Orca macOS provider 契约、观察、动作、权限 |
| Agent 上下文 | apps/runtime/src/daemon/env.ts、daemon.ts、index.ts | 注入 Workspace 与 Session 上下文，不注入长期密钥 |
| CLI 与 skills | 现有 apps/cli/src/cli.ts、args.ts、client.ts、测试、scripts/e2e-cli.ts 与打包脚本 | Workspace、只读文件/Git/端口、browser、emulator、computer、doctor 和稳定 JSON 输出 |
| 桌面端 | RuntimeConnection.swift、WorkbenchLayoutState.swift、WorkbenchModel.swift、WorkbenchView.swift、TerminalPanesView.swift | 能力、布局迁移、四种 Surface UI 与输入 |
| 移动端 | apps/mobile/App.tsx、src/client.ts、src/surface.ts、相应原生模块与测试 | 能力隐藏、二进制解码、输入和控制权 |
| 移动工作台 | apps/mobile/App.tsx、src/client.ts、src/storage、必要的新路由与测试 | 多服务器、Workspace/分组、目录选择、Surface 导航 |
| Agent 状态 | packages/protocol、apps/runtime/src/daemon、apps/runtime/src/index.ts、Desktop/Mobile 状态 UI | 受限 OSC 适配器、通用状态、提问与会话定位 |
| 通知 | packages/protocol、apps/runtime/src/devices.ts、通知存储模块、apps/mobile | 持久通知、按设备未读、push token、后台唤醒 |
| 诊断 | server.info、RuntimeConnection、ServerSheets/SettingsView、Mobile troubleshoot 路由 | 兼容闸门、能力/依赖/权限、连接日志和诊断报告 |
| 打包发布 | apps/desktop-macos/scripts/package-app.sh、Package.swift、发布工作流和第三方说明 | 工具物化、签名、公证、许可证、包内自检 |
| 蓝图 | .planning/blueprint.md | 仅在最终实现改变架构边界或验收标准时更新 |

## 实施阶段

### 阶段 -1：裁决 Workspace / Project 唯一契约

入口条件：

- 用户确认 Acro 是否仍需要显式 Project 实体和 Workspace 项目归属。

实现内容：

1. 把用户决定写入 AGENTS.md 与 `.planning/blueprint.md`，删除相反契约。
2. 若保持纯 Workspace 容器，补齐文档、验收和移动端 cwd 选择流程，不增加 Project 代码。
3. 若恢复 Project，先补充 schema、持久化迁移、RPC、鉴权、codegen、客户端入口和回滚方案，再进入阶段 0。
4. 更新本计划后续阶段的路径、环境变量和验收；只有恢复 Project 时才允许引入 ACRO_PROJECT_ID。

验证：

- AGENTS.md、蓝图、协议模型、Runtime 存储和客户端术语只保留一套一致契约。
- 现有 Workspace 数据可以无损读取；需要迁移时必须有旧数据夹具和回滚测试。

完成标准：

- 项目归属不再是文档与代码互相矛盾的隐含假设。
- 阶段 0 和阶段 2 可以按同一数据模型实施。

### 阶段 0：冻结协议和兼容夹具

入口条件：

- 阶段 -1 已完成，Workspace / Project 只有一套权威契约。
- 当前 Runtime、Protocol、Mobile 和 Swift helper 基线测试保持通过。
- 保存一份版本 1 Workspace 布局夹具和旧客户端 attach 请求夹具。

实现内容：

1. 新增 SurfaceRef、ControlOwner、ServerInfo、能力项和 RpcErrorCode schema。
2. 新增版本 2 画面帧编码、解码和边界校验。
3. 为 browser.attach 与 simulator.attach 增加可选 streamVersion。
4. 为 computer 增加 attach 与 detach 画面订阅契约。
5. 生成 Swift 类型并更新 TypeScript 导出。

验证：

- Protocol schema、frame round-trip、短帧、未知 codec、非法尺寸和序号测试。
- Swift codegen 无手工差异。
- 旧请求仍可解析，旧帧仍可解码。

完成标准：

- 新旧客户端兼容规则由自动化夹具固定。
- 后续阶段不再自行发明 Surface 身份、错误码或帧格式。

### 阶段 1：Runtime 能力、错误和共享流控

入口条件：

- 阶段 0 协议已合入。

实现内容：

1. 在 RPC 分发边界集中映射稳定错误码。
2. 实现 server.info，并从实际平台、可执行文件、helper 握手与权限返回能力。
3. 扩展连接状态，记录版本 2 Surface channel 与订阅。
4. 把最新帧覆盖、缓冲阈值和连接关闭清理放在共享发送路径。
5. 复用 ExclusiveRunner 串行化同一 Surface 的控制权、关闭和生命周期操作。
6. 记录 server.info、依赖探测、权限探测和最近连接失败，提供结构化 diagnostics.snapshot RPC。

验证：

- macOS、非 macOS、依赖缺失、权限缺失和旧方法探测测试。
- 慢 WebSocket、断线、重连、同设备多连接和强制接管测试。
- 现有终端 e2e 全量回归。

完成标准：

- 客户端可以只靠 server.info 和稳定错误码决定入口与提示。
- 慢观察者不会拖慢 Surface 生产者或其他观察者。
- 桌面端与移动端可以用同一份诊断快照解释版本不兼容、依赖缺失、权限缺失和入口不可达。

### 阶段 2：Workspace 与客户端 Surface 布局

入口条件：

- 阶段 1 能返回能力和版本 2 画面帧。

实现内容：

1. 把 WorkbenchLayoutState 的 sessionIds 改为 SurfaceRef 列表。
2. 增加版本 1 到版本 2 的解码迁移，并保留现有分屏、拖拽、快捷键和选中语义。
3. RuntimeConnection 保存 server.info 和各领域控制权。
4. Workbench 根据能力显示创建入口；Surface 已消失时按服务端列表清理引用。
5. 终端专属操作只对 terminal Surface 生效。普通切换、分屏和从布局移除操作对四种 Surface 共用。
6. 生命周期按领域处理：关闭 Terminal 保留现有终止确认；关闭 Browser 关闭对应 Page；关闭 Simulator 或 Computer 只停止观看并移出布局，shutdown 或系统动作必须显式触发。
7. 移动端改为 Server → Workspace → Surface 导航，加载 workspaceGroup.list、workspace.list 和 session.list，不再把全部 Session 平铺在主页。
8. 移动端创建 Workspace 后，按阶段 -1 的唯一契约选择 Project 或 cwd 并创建第一个终端。
9. 桌面端与移动端使用同一 scoped identity 组合 serverId、workspaceId 和 SurfaceRef，避免多主机同 ID 串台。

验证：

- 旧布局迁移、混合 Surface 布局、拖拽、分屏、领域关闭语义、重连和失效引用测试。
- 现有终端快捷键、focus owner、cwd 继承和布局同步回归。
- 移动端多服务器切换、Workspace 分组、空 Workspace、目录选择、会话创建和同 ID 多主机隔离测试。

完成标准：

- 一个 Workspace 可以保存并恢复混合 Surface。
- 终端行为没有因通用布局迁移退化。
- iPhone 可以创建和进入 Workspace，并在明确工作目录中创建终端。

### 阶段 3：Browser Runtime 与 Agent 自动化

入口条件：

- 阶段 1 的能力、错误和流控可用。
- 固定 agent-browser 版本和校验值已进入锁文件与第三方清单。

实现内容：

1. 保留 BrowserManager 的持久 Chromium profile、Page.screencast 和输入路径。
2. 为每个 browserId 建立只监听回环地址的短期 CDP lease。lease 只暴露目标页面，不暴露整个浏览器。
3. 参考 Orca 的 agent-browser bridge 与 CDP proxy，只移植目标隔离、超时、队列和错误映射所需部分。
4. acro browser 负责解析当前 Workspace、选择 browser Surface、获取 lease，并执行打包的 agent-browser。
5. agent-browser 继续实现 snapshot、ref、click、fill、type、wait、screenshot、eval 等自动化命令；Acro 不复制这些命令。
6. Browser list 和事件返回真实 title 与 URL，工作台标签随页面变化更新。
7. UI 继续通过 Acro E2EE 画面与输入通道控制浏览器，不连接 CDP。

验证：

- 多页面目标隔离、lease 过期、CLI 中断、浏览器关闭和 Runtime 断线测试。
- 浏览器标题与 URL 变化、画面尺寸、点击映射、键盘、滚轮、慢客户端丢帧测试。
- 真实网页完成 open、snapshot、ref click、fill、wait 和 screenshot。
- 确认 CDP 端口不监听 LAN 地址。

完成标准：

- Agent 可以在 Workspace 终端里操作指定 Browser Surface。
- 远程用户可以同时观看，且只有控制权持有者可以输入。

### 阶段 4：iOS Simulator 实时画面与输入

入口条件：

- 阶段 1 的版本 2 画面通道与控制权规则可用。
- 固定 serve-sim 版本和校验值已进入锁文件与第三方清单。

实现内容：

1. simctl 继续负责 list、boot、shutdown、install、launch 和日志获取；serve-sim 只负责实时画面与输入。
2. attach 时由 Runtime 启动自己持有的 serve-sim detached 会话，等待本机 MJPEG endpoint 就绪。
3. Runtime 解析 MJPEG 边界，提取 JPEG、尺寸和旋转后转为版本 2 画面帧。
4. 点击、拖动、滑动、文字和硬件按键通过 serve-sim 本机控制通道发送。
5. 增加 Simulator 控制权、断线释放、重复 attach、启动冲突和 helper 清理。
6. 只清理由 Acro 启动并记录的 serve-sim 进程，不杀外部实例。
7. 包内 serve-sim 按版本物化到 ~/.acro 工具目录，修正执行权限并避免对签名包原地写入。
8. 新增 simulator.install、simulator.launch 和有界日志读取契约；路径必须位于目标 Runtime，可执行 App 标识和日志参数必须校验。

验证：

- MJPEG 分块、跨 chunk 边界、坏帧、旋转、断流和重连测试。
- 同一 UDID 多观察者、控制权接管、boot 或 shutdown 与 attach 竞态测试。
- 真机验证启动 Simulator、实时画面、tap、swipe、type、home 和旋转。
- 验证安装 .app、启动 bundle identifier、获取有界日志，以及错误路径、无效 bundle 和日志超限。
- 确认远程客户端未收到 localhost URL。

完成标准：

- 远程画面达到交互可用，不再依赖 simctl screenshot 轮询。
- Simulator 生命周期和流进程退出后没有遗留 Acro 所属 helper。

### 阶段 5：macOS Computer Use provider

入口条件：

- 阶段 1 的能力、稳定错误和画面通道可用。
- Orca MIT 版权说明和取用文件清单已记录。

实现内容：

1. 用 Orca macOS provider 的版本化 handshake、observe、snapshot cache 和 action 契约替换当前简化 helper 协议。
2. 只移植 macOS 实现，不建立跨平台 provider 工厂。
3. observe 返回 snapshotId、屏幕元数据、可访问性树和可选截图。Runtime 把截图转成版本 2 画面帧。
4. action 支持坐标和 snapshot ref，并覆盖点击、双击、右键、移动、拖拽、滚动、输入、组合键、粘贴、应用与窗口激活。
5. helper 校验 snapshot 生命周期、元素身份、参数长度和 deadline；过期引用返回稳定错误。
6. Runtime 继续通过 Unix socket 串行请求，保留队列上限、超时、取消和连接重建。
7. helper 保持固定 bundle identifier、签名主体和权限引导。

验证：

- provider handshake、协议版本不匹配、权限缺失、snapshot 过期和非法 action 测试。
- 多显示器坐标、缩放、窗口激活、中文输入、粘贴和组合键测试。
- helper 崩溃、socket 重连、慢请求和控制权接管测试。
- 发布包中 Accessibility 与 Screen Recording 权限能稳定识别同一 helper。

完成标准：

- Agent 和客户端都能基于同一 provider 观察并操作 macOS。
- Runtime 不再依赖字符串匹配 helper 错误或未知 windows 结构。

### 阶段 6：移动端原生画面 Surface

入口条件：

- Browser、Simulator 和 Computer Use 都能产生版本 2 画面帧。
- 已阅读 Expo 57 精确版本文档并确定最小原生模块接口。

实现内容：

1. 移除每帧 Uint8Array 转 base64 data URI 的路径。
2. 增加小型原生 SurfaceImageView：接收二进制 JPEG 或 PNG，后台解码，只提交最新 CGImage 或平台图像。
3. JavaScript 只传 channel、seq、codec、尺寸和旋转，不保存历史帧。
4. 用统一坐标映射处理 contain 留白与旋转。
5. 按 server.info 隐藏不可用入口，并显示控制权与权限状态。

验证：

- 连续高帧率输入下的内存、JS 线程延迟和最新帧覆盖测试。
- 浏览器、Simulator 和 Computer Use 的尺寸、旋转、点击映射和断线恢复测试。
- iPhone 与 iPad 真实设备经 LAN 和公网入口验证。

完成标准：

- 正式画面路径不再创建 base64 data URI。
- 长时间观看不会出现持续增长的延迟或内存。

### 阶段 7：Agent CLI、skills 与终端上下文

入口条件：

- 至少一个领域具备可运行 Runtime 能力，不创建空 CLI。

实现内容：

1. 扩展现有 apps/cli，复用 AcroClient、参数解析、WebSocket 背压、packages/protocol 和 ~/.acro/client.json。
2. 增加 acro workspaces list/create/update/remove，以及按阶段 -1 契约选择 Project 或 cwd 的会话创建入口。
3. 增加只读 acro file list/read/search、acro git status/diff 和 acro ports list；不得提供任意 RPC 透传或 Git/文件写入。
4. acro browser 包装 Browser Surface 选择与 agent-browser 执行。
5. acro emulator 提供 list、boot、shutdown、install、launch、logs、tap、swipe、type、key 和 screenshot。
6. acro computer 提供 permissions、observe、click、drag、scroll、type、key、paste 和 activate。
7. 增加 acro doctor，输出 server.info、diagnostics.snapshot、入口探测和协议兼容结论。
8. 所有列表和查询命令提供稳定 `--json` 输出；命令注册表与帮助文本做一致性检查。
9. 新终端注入 ACRO_SERVER_ID、ACRO_WORKSPACE_ID 和 ACRO_SESSION_ID。环境中不放长期 token；只有阶段 -1 恢复 Project 时才注入 ACRO_PROJECT_ID。
10. CLI 继续通过现有 AcroClient 和 ~/.acro/client.json 连接 Runtime；环境变量只提供当前上下文，缺少或歧义时给出可操作错误。
11. skills 与 CLI 源码、命令帮助和版本一起打包。skill 只说明选择资源和调用命令，不复制工具实现。

验证：

- 环境注入、旧 daemon 兼容、无上下文、多个 Surface、显式选择和错误码测试。
- CLI 命令注册、帮助、`--json` schema 与 skill 中出现的命令逐条执行。
- 对 Workspace、文件、Git、端口、Browser、Simulator、Computer 和 doctor 跑真实 CLI E2E；确认不存在任意 RPC 透传。
- 发布包内 CLI、agent-browser、serve-sim 和 helper 版本完全一致。

完成标准：

- Workspace 内 Agent 无需猜服务、Workspace 或 Surface ID。
- skill 文档不会与用户机器上的 CLI 版本漂移。

### 阶段 7A：通用 Agent 状态、提问与审批

入口条件：

- 阶段 0 已冻结 AgentActivity、AgentRequest 和对应事件 schema。
- 终端 daemon 可以安全识别带版本、长度上限和 Acro namespace 的显式 OSC 消息。

实现内容：

1. terminal daemon 解析显式 Agent OSC 消息，并把它绑定到当前 sessionId；普通 PTY 内容继续透明转发。
2. Runtime 保存每个存活 Session 的最新 AgentActivity 和未解决 AgentRequest，Session 删除时一并清理。
3. 为 Codex、Claude Code 等已确认有 hook 的 Agent 提供独立薄适配器。适配器只把供应商事件规范化，不进入 Runtime 核心。
4. 桌面侧边栏和移动 Workspace 显示 working、needs_user、done、error；点击状态直接定位会话。
5. AgentRequest 的选项通过现有终端 input 发送 answerText，并遵守 session.claimFocus 与显式接管规则。
6. 适配器不可用、事件未知或 schema 不匹配时安全忽略，不把终端标题或普通文本猜成状态。

验证：

- OSC 分块、超长、未知版本、伪造普通文本、Session 退出和重连测试。
- 有适配器与无适配器 Agent 的降级测试。
- 多设备同时查看、显式接管、选项回答和自由文本回答测试。
- Runtime 重启后仍能从 Session 当前事实恢复，不把旧 request 误报为未解决。

完成标准：

- 用户可以从桌面或移动端识别哪个 Session 正在工作、完成、失败或等待输入。
- Runtime 不包含供应商专用解析器，也不解析普通终端输出。

### 阶段 7B：通知与未读

入口条件：

- 阶段 7A 可以产生稳定的 needs_user、done 和 error 事件。
- 设备授权模型可以标识当前 deviceId，并在撤销时执行清理。

实现内容：

1. Runtime 持久化 NotificationRecord，并为每个设备维护已读集合和拉取游标。
2. 新增 notification.list、notification.markRead、notification.unreadCount 和 device.setPushToken。
3. 前台客户端通过 E2EE 事件即时更新未读；断线重连后通过游标补齐，不依赖事件恰好在线送达。
4. 移动端接入 expo-notifications。后台推送只发送固定文案和 opaque notificationId，不发送仓库、问题或终端内容。
5. App 打开通知后连接对应 Server，读取真实记录并定位 Workspace 与 Session。
6. 设备撤销、token 轮换、推送失败和通知保留上限都由 Runtime 处理；推送失败不丢通知。

验证：

- 通知持久化、去重、分页、按设备已读、撤销设备和保留上限测试。
- App 前台、后台、离线、推送 token 失效和多服务器同 ID 路由测试。
- 抓包确认推送服务收不到敏感正文、路径、token 或终端内容。

完成标准：

- iPhone 离线期间产生的 needs_user、done 和 error 在恢复后都能看到。
- 后台推送只是唤醒提示，真实内容始终从对应 Runtime 的 E2EE 连接读取。

### 阶段 7C：用户可操作诊断与协议兼容

入口条件：

- 阶段 1 已提供 server.info、稳定错误码和 diagnostics.snapshot。

实现内容：

1. 桌面服务器设置页显示 Runtime/协议版本、平台、能力、依赖、权限、当前入口和最近连接失败。
2. 移动端增加协议兼容闸门和故障排查页；不兼容时阻止进入工作台并说明升级哪一端。
3. 客户端可以导出脱敏诊断报告，包含版本、能力、连接阶段和错误码，不包含 token、终端内容或文件内容。
4. 对入口不可达、Runtime 未启动、协议过旧、依赖缺失和权限缺失给出对应操作，不只显示“连接失败”。

验证：

- 新客户端连旧 Runtime、旧客户端连新 Runtime、方法缺失和能力缺失测试。
- LAN 入口失败后公网回退、认证失败、设备撤销和权限缺失的 UI 测试。
- 诊断报告敏感字段审计。

完成标准：

- 用户可以区分网络、认证、版本、依赖和系统权限问题，并获得与根因对应的处理动作。
- 没有可用能力时客户端不会展示空白或必然失败的入口。

### 阶段 8：打包、发布与真实端到端验收

入口条件：

- 各领域针对性测试、类型检查和 Swift 测试全部通过。

实现内容：

1. package-app.sh 打包固定版本 agent-browser、serve-sim、helper、CLI 和 skills。
2. 生成第三方软件清单，包含版本、许可证、来源、版权和取用文件。
3. 在签名前校验嵌套可执行文件权限；签名后验证 codesign、spctl、公证和 stapler。
4. 对 serve-sim 使用包外版本目录，不修改已签名 App。
5. 发布工作流执行包内自检和真实能力探测。
6. 打包 Agent 适配器与通知所需移动端配置，并验证它们与协议版本一致。

验证：

- 干净机器安装后无需全局 npm 包即可使用三类 CLI。
- Mac mini 上建立 Workspace 和四种 Surface。
- MacBook、iPhone、iPad 同时观看；逐一测试接管、断线、重连和慢网。
- Runtime/UI 热替换时保留终端 daemon 会话；浏览器、Simulator 与 Computer Use 按 server.info 和真实列表重新同步。
- 从非 macOS Runtime 连接时只显示真实支持能力。
- 关闭 iPhone 网络后制造 needs_user 与 done，恢复网络后验证未读补齐和会话定位。
- 验证协议不兼容、helper 权限缺失和浏览器依赖缺失都有可操作诊断。

完成标准：

- 发布包包含全部运行时依赖和许可证。
- 真实远程链路完成画面、输入、Agent 自动化、控制权和恢复验收。

## 验证方式

| 层级 | 必须执行 |
|---|---|
| Protocol | pnpm --filter @acro/protocol test、check、codegen 差异检查 |
| Runtime 单测 | pnpm --filter @acro/runtime test、check |
| Runtime 集成 | e2e、e2e:browser、e2e:simulator、e2e:computer |
| Desktop | setup-ghostty 后执行 Swift build 与 Swift tests |
| Mobile | pnpm --filter @acro/mobile check、test；原生模块构建与真实设备测试 |
| Agent 状态 | daemon OSC parser、适配器夹具、状态/提问/回答、多设备接管与降级测试 |
| 通知 | Runtime 持久化、按设备未读、推送隐私、离线补齐和通知路由测试 |
| 诊断 | server.info/diagnostics 兼容矩阵、依赖/权限/入口故障和脱敏报告测试 |
| 客户端可达性 | 扫描正式 Desktop/Mobile/CLI 调用点；目标 RPC 必须有可到达入口和对应测试 |
| 打包 | package-app、嵌套签名检查、codesign、spctl、公证、stapler |
| 安全 | CDP 与 MJPEG 仅回环可达、E2EE 远程帧、输入长度和权限校验 |
| 体验 | 多设备观察、单一控制权、旋转、慢网丢帧、断线重连、混合布局恢复 |

## 执行状态

- 只读探索：已完成。
- 完整规划：已在 2026-07-23 补齐 9 个核心差异模块和 Project 规格决策门。
- 产品实现：本轮未开始，先执行阶段 -1，再按阶段 0 至 8（含 7A、7B、7C）执行。
- 产品验证与发布：本轮未开始，不属于本轮 planning-only 完成判断。
- Git 收尾：在三份 planning 文件通过完整性检查后执行。

## 决策

| 决策 | 理由 |
|---|---|
| 统一 SurfaceRef，不统一所有领域 RPC | 布局、控制权和画面确有共性；领域生命周期不同 |
| 固定并复用 agent-browser | 避免重写成熟的 Agent 浏览器自动化 |
| 用 serve-sim 替换截图轮询 | 当前约 1fps PNG 轮询无法承担交互 |
| 移植 Orca macOS provider | 当前 helper 契约缺少稳定观察、ref 和动作语义 |
| 画面继续走现有 E2EE WebSocket | 复用安全边界，避免暴露 localhost 与新增媒体服务 |
| 版本 2 画面使用完整 JPEG 或 PNG | 已满足当前需求；视频编码没有确认收益 |
| 客户端保留最新帧 | 远程控制优先低延迟，不要求逐帧播放 |
| CLI 与 skills 同版本发布 | 避免命令和说明漂移 |
| 不把 Browser 下沉 daemon | 当前只要求客户端断开不杀 Surface；profile 已持久化 |
| 移动端按 Server → Workspace → Surface 导航 | 全局 Session 平铺无法表达工作上下文，也会在多主机下产生身份歧义 |
| Workspace / Project 由阶段 -1 裁决 | 文档与代码冲突属于架构契约，planning 不能替用户暗选 |
| Agent 状态使用显式 OSC 适配器 | 不解析普通 PTY 内容，也不把供应商逻辑放进 Runtime 核心 |
| 审批回答复用终端输入权 | Agent 的真实交互界面仍是 PTY，无需增加供应商私有审批 API |
| Runtime 持有通知和按设备未读 | iOS 后台可能断开，在线事件不能证明通知可靠送达 |
| Push 只发送 opaque 唤醒信息 | 推送服务不进入 Acro 的敏感数据可信边界 |
| 诊断快照与 server.info 共用事实源 | UI 不应靠字符串错误猜网络、权限、依赖或版本根因 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| planning worktree 看不到被 Git 忽略的 .tmp 参考目录 | 1 | 改从主 checkout 只读参考，不复制或修改参考源码 |
| development-guard 在模板未填写时阻止继续搜索 | 1 | 尊重守门，先完成三份 planning 文件，再继续检查 |
