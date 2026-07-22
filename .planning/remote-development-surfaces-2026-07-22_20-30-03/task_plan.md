# 任务计划：remote-development-surfaces

- 任务 ID：remote-development-surfaces-2026-07-22_20-30-03
- 创建时间：2026-07-22_20-30-03
- 本轮交付：完整规划，不实现产品代码

## 目标

把终端、浏览器、iOS Simulator 和 macOS Computer Use 纳入同一套远程 Workspace 工作台。Runtime 继续持有真实进程、画面和控制状态。桌面端与移动端只负责显示和输入。Agent 在 Workspace 终端中通过随 Acro 发布的 CLI 和 skills 操作这些能力。

完成实现后，系统必须满足以下结果：

1. Workspace 布局可以同时保存四种 Surface，并能从现有只保存终端 sessionIds 的布局无损迁移。
2. 客户端连接后通过 server.info 识别服务端平台、协议版本和可用能力，不向用户展示服务端不支持的入口。
3. 浏览器继续由 Runtime 的 Chromium 提供画面和输入，同时由固定版本 agent-browser 提供 Agent 自动化能力。
4. iOS Simulator 使用 serve-sim 提供实时画面和输入，simctl 只负责设备发现、启动和关闭。
5. Computer Use 使用移植后的 Orca macOS provider 提供可验证的观察和动作，不再依赖当前简化 helper 契约。
6. 所有远程画面都经过现有 E2EE WebSocket 转发。客户端不会收到只能在 Mac mini 本机访问的 localhost 地址。
7. 多设备可以同时观看同一 Surface，但同一时刻只有一个设备可以输入。断线、重连和显式接管都遵循一致规则。
8. 桌面端和移动端只渲染最新画面。慢客户端不会把延迟持续堆积到服务端或 UI。

## 范围

- 协议：SurfaceRef、能力协商、稳定错误码、控制权模型、版本化画面帧和 Swift codegen。
- Runtime：浏览器、Simulator、Computer Use 的生命周期、画面转发、输入、背压、控制权和断线清理。
- Workspace：桌面布局从终端 ID 列表迁移为 Surface 引用列表。
- 桌面端：四种 Surface 的列表、打开、分屏、切换、关闭、画面显示、输入和控制权提示。
- 移动端：能力隐藏、浏览器与 Simulator 控制、Computer Use 入口、原生二进制画面解码。
- Agent 工具：acro browser、acro emulator、acro computer，以及与 CLI 同版本发布的 skills。
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
| CLI 与 skills | 现有 apps/cli/src/cli.ts、args.ts、client.ts、测试与打包脚本 | 扩展 browser、emulator、computer 命令和版本一致的说明 |
| 桌面端 | RuntimeConnection.swift、WorkbenchLayoutState.swift、WorkbenchModel.swift、WorkbenchView.swift、TerminalPanesView.swift | 能力、布局迁移、四种 Surface UI 与输入 |
| 移动端 | apps/mobile/App.tsx、src/client.ts、src/surface.ts、相应原生模块与测试 | 能力隐藏、二进制解码、输入和控制权 |
| 打包发布 | apps/desktop-macos/scripts/package-app.sh、Package.swift、发布工作流和第三方说明 | 工具物化、签名、公证、许可证、包内自检 |
| 蓝图 | .planning/blueprint.md | 仅在最终实现改变架构边界或验收标准时更新 |

## 实施阶段

### 阶段 0：冻结协议和兼容夹具

入口条件：

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

验证：

- macOS、非 macOS、依赖缺失、权限缺失和旧方法探测测试。
- 慢 WebSocket、断线、重连、同设备多连接和强制接管测试。
- 现有终端 e2e 全量回归。

完成标准：

- 客户端可以只靠 server.info 和稳定错误码决定入口与提示。
- 慢观察者不会拖慢 Surface 生产者或其他观察者。

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

验证：

- 旧布局迁移、混合 Surface 布局、拖拽、分屏、领域关闭语义、重连和失效引用测试。
- 现有终端快捷键、focus owner、cwd 继承和布局同步回归。

完成标准：

- 一个 Workspace 可以保存并恢复混合 Surface。
- 终端行为没有因通用布局迁移退化。

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

1. simctl 继续负责 list、boot 和 shutdown。
2. attach 时由 Runtime 启动自己持有的 serve-sim detached 会话，等待本机 MJPEG endpoint 就绪。
3. Runtime 解析 MJPEG 边界，提取 JPEG、尺寸和旋转后转为版本 2 画面帧。
4. 点击、拖动、滑动、文字和硬件按键通过 serve-sim 本机控制通道发送。
5. 增加 Simulator 控制权、断线释放、重复 attach、启动冲突和 helper 清理。
6. 只清理由 Acro 启动并记录的 serve-sim 进程，不杀外部实例。
7. 包内 serve-sim 按版本物化到 ~/.acro 工具目录，修正执行权限并避免对签名包原地写入。

验证：

- MJPEG 分块、跨 chunk 边界、坏帧、旋转、断流和重连测试。
- 同一 UDID 多观察者、控制权接管、boot 或 shutdown 与 attach 竞态测试。
- 真机验证启动 Simulator、实时画面、tap、swipe、type、home 和旋转。
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
2. acro browser 包装 Browser Surface 选择与 agent-browser 执行。
3. acro emulator 提供 list、boot、shutdown、tap、swipe、type、key 和 screenshot。
4. acro computer 提供 permissions、observe、click、drag、scroll、type、key、paste 和 activate。
5. 新终端注入 ACRO_SERVER_ID、ACRO_WORKSPACE_ID 和 ACRO_SESSION_ID。环境中不放长期 token。
6. CLI 继续通过现有 AcroClient 和 ~/.acro/client.json 连接 Runtime；环境变量只提供当前上下文，缺少或歧义时给出可操作错误。
7. 三份 skill 与 CLI 源码、命令帮助和版本一起打包。skill 只说明选择 Surface 和调用命令，不复制工具实现。

验证：

- 环境注入、旧 daemon 兼容、无上下文、多个 Surface、显式选择和错误码测试。
- CLI 帮助与 skill 中出现的命令逐条执行。
- 发布包内 CLI、agent-browser、serve-sim 和 helper 版本完全一致。

完成标准：

- Workspace 内 Agent 无需猜服务、Workspace 或 Surface ID。
- skill 文档不会与用户机器上的 CLI 版本漂移。

### 阶段 8：打包、发布与真实端到端验收

入口条件：

- 各领域针对性测试、类型检查和 Swift 测试全部通过。

实现内容：

1. package-app.sh 打包固定版本 agent-browser、serve-sim、helper、CLI 和 skills。
2. 生成第三方软件清单，包含版本、许可证、来源、版权和取用文件。
3. 在签名前校验嵌套可执行文件权限；签名后验证 codesign、spctl、公证和 stapler。
4. 对 serve-sim 使用包外版本目录，不修改已签名 App。
5. 发布工作流执行包内自检和真实能力探测。

验证：

- 干净机器安装后无需全局 npm 包即可使用三类 CLI。
- Mac mini 上建立 Workspace 和四种 Surface。
- MacBook、iPhone、iPad 同时观看；逐一测试接管、断线、重连和慢网。
- Runtime/UI 热替换时保留终端 daemon 会话；浏览器、Simulator 与 Computer Use 按 server.info 和真实列表重新同步。
- 从非 macOS Runtime 连接时只显示真实支持能力。

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
| 打包 | package-app、嵌套签名检查、codesign、spctl、公证、stapler |
| 安全 | CDP 与 MJPEG 仅回环可达、E2EE 远程帧、输入长度和权限校验 |
| 体验 | 多设备观察、单一控制权、旋转、慢网丢帧、断线重连、混合布局恢复 |

## 执行状态

- 只读探索：已完成。
- 完整规划：已完成。
- 产品实现：本轮未开始，按阶段 0 至阶段 8 执行。
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

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| planning worktree 看不到被 Git 忽略的 .tmp 参考目录 | 1 | 改从主 checkout 只读参考，不复制或修改参考源码 |
| development-guard 在模板未填写时阻止继续搜索 | 1 | 尊重守门，先完成三份 planning 文件，再继续检查 |
