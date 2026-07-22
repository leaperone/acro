# 调研与结论：remote-development-surfaces

- 任务 ID：remote-development-surfaces-2026-07-22_20-30-03
- 创建时间：2026-07-22_20-30-03
- 调研方式：仓库源码、现有测试、蓝图、只读参考源码、本机已安装工具与 npm 元数据

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

1. 客户端调用 browser.open。
2. apps/runtime/src/index.ts 把请求交给 BrowserManager。
3. apps/runtime/src/browser.ts 使用 playwright-core 启动持久 Chromium context，在 Mac mini 创建 Page。
4. browser.attach 返回连接内 channel，并启动 Page.startScreencast。
5. CDP Page.screencastFrame 产生 JPEG。Runtime 经 FRAME_BROWSER 和 E2EE WebSocket 发给订阅客户端。
6. 客户端通过 browser.input 发送点击、移动、滚轮、按键和文字。
7. Runtime 用设备级 Browser control owner 阻止非持有者输入。

当前缺口：

- Browser Surface 没有进入桌面 Workspace 布局。
- Agent 没有稳定方式选择并操作指定 browserId。
- agent-browser 未随 Acro 固定版本打包。
- 当前帧不携带 codec、尺寸变化和旋转元数据。
- CDP screencast 总是立即 ack，发送层没有按连接缓冲执行背压。

### Simulator

1. 客户端调用 simulator.list、boot、shutdown。
2. apps/runtime/src/simulator.ts 通过 xcrun simctl 管理设备。
3. simulator.attach 启动 simctl io screenshot 轮询。
4. 每次截图生成 PNG，并经 FRAME_SIM 与 E2EE WebSocket 发送。
5. apps/mobile/App.tsx 把字节转成 base64 data URI 后交给 React Native Image。

当前缺口：

- 截图轮询约 1fps，不能承担交互。
- 没有触摸、滑动、输入和硬件键。
- 没有 Simulator 控制权。
- attach 只返回 channel，不返回稳定尺寸和旋转。
- base64 data URI 会复制数据并占用 JS 线程，不适合持续画面。

### Computer Use

1. 客户端调用 computer.permissions、capture、windows 或动作 RPC。
2. apps/runtime/src/index.ts 校验 Computer control owner。
3. apps/runtime/src/computer.ts 通过 Unix socket 向 helper 发送 NDJSON。
4. apps/helper-macos/Sources/main.swift 使用 CoreGraphics 和 Accessibility 执行截图与动作。
5. capture 把 PNG 作为 base64 放进 JSON RPC 返回。

当前缺口：

- helper 没有版本化 handshake。
- windows 返回 unknown 数组，Runtime 没有稳定 schema。
- 没有 snapshotId、元素 ref、缓存生命周期和可验证动作。
- 截图经本机 base64 JSON 再经远程 JSON，内存和协议开销过大。
- helper 错误是字符串，客户端无法稳定处理权限、过期引用和无效状态。

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
- .tmp/cmux/Packages/macOS/CmuxBrowser
- .tmp/cmux/Packages/iOS/CmuxMobileBrowser
