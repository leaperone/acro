# 调研与结论：desktop-performance-robustness

- 任务 ID：`desktop-performance-robustness-2026-07-23_14-19-19`
- 创建时间：`2026-07-23_14-19-19`

## 需求事实

- 用户目标不是单点微优化，而是减少简单操作卡顿、关闭交互死胡同并提高鲁棒性。
- 当前运行的是 main 构建的 Acro dev app；UI、runtime 和 daemon 均存活，daemon 独立持有 PTY。
- 真实窗口当前显示终端被另一设备占用，存在显式“在此设备继续使用”入口；不能为测试擅自抢占用户正在使用的会话。
- main 与 origin/main 同为 `a6d6fd46`；主 checkout 仅有用户现存 release skill 修改。

## 真实调用链

- 非 `session.title` 事件进入 `RuntimeConnection.handleControl` 后统一 `scheduleRefresh()`。
- 一次 refresh 顺序请求 workspaceGroup、workspace、session、focus 四个列表，再逐字段发布快照。
- `RuntimeHub` 当前把每个子连接的裸 `objectWillChange` 再广播给所有观察者，导致其他服务器和整个侧边栏一起失效。
- `session.claimFocus` 会先广播 `session.focusChanged` 再返回 RPC；桌面端收到事件会全量 refresh，`WorkbenchModel.claimFocus` 在 RPC 返回后又主动 refresh，形成连续两轮快照。
- `snapshotRevision` 触发 `reconcileLayoutState`；该方法扫描全部已加载服务器，并可逐工作区写回 `workspaceLayouts`，每次写回都会重建持久化与布局同步去抖任务。
- 文件 / Git / 端口面板的状态对象会跨服务器长期存活；任务 key 缺少 runtime identity，重复刷新也没有 single-flight 或请求代次。
- `RuntimeConnection.rpc` 的外层 Task 取消不会完成 pending continuation，请求和 timeout task 最长保留 30 秒。
- 无效 endpoint / 公钥让 `openSocket()` guard 直接返回；合法 WebSocket 不发 ready 时没有握手期限。
- `LocalRuntimeManager` 只尝试启动一次；本机 runtime 退出后没有恢复循环。
- daemon restart UI 承诺自动创建新终端，但实现只发送重启 RPC，没有等待重连和创建会话。

## 调研结论

- 最先应修的根因是“事件过度刷新 + Hub 全局广播 + reconcile 多次发布”，而不是继续给单个按钮加 loading。
- `session.focusChanged` 的 payload 已足够增量更新；移动端已经采用该方式，桌面无需刷新四个列表。
- Hub 仍需广播低频连接状态和服务器目录变化，但不应广播 sessions、focus、workspace 等所有子状态；每个服务器段可直接观察自己的连接。
- 面板 stale state、取消失效和乱序覆盖属于同一个请求所有权问题，应共用 runtime identity + generation 规则。
- 连接 guard、握手悬挂、本机 runtime 崩溃和 daemon 重启都缺少完成事务；这些是真实交互死胡同。
- 命令面板每次 body、方向键和 hover 都重建搜索语料；大图片 base64 解码和大 diff 行树也在主线程，应在后续阶段处理。
- daemon RPC 响应和 attach replay 仍绕过已有 8 MiB 发送队列限制；大快照会放大内存和事件循环延迟。
- `FrameReader.push` 对每个 socket chunk 执行 `Buffer.concat([累计缓冲, 新块])`；大型分片帧会重复复制全部前缀，复杂度呈 O(n²)。

## 技术决策

| 决策 | 证据 |
|---|---|
| 焦点事件本地增量应用 | protocol payload 含 sessionId、deviceId、deviceName；移动端已直接消费。 |
| Hub 只转发连接状态 | 设置页需要连接统计和认证后配置刷新；侧边栏内容由单服务器观察边界负责。 |
| reconcile 使用局部副本单次提交 | 当前逐项写 `@Published` 会反复触发持久化和同步任务。 |
| 取消先本地收口 | 协议没有 RPC cancel；先保证 pending 立即释放和旧响应不再改 UI，服务端取消另需协议设计。 |
| 不在本轮扩展协议级 cancel | 该改动会改变协议信封和全部 handler 的取消契约；当前任务先完成不改外部协议即可根治的发送背压与解析复制。 |
| daemon 大响应复用现有 8 MiB 水位 | 空队列允许发送一个大帧；已有积压时超过水位即断开，等待 drain 后再发送 replay。 |
| FrameReader 改为 chunk 队列 | 只在完整跨块 body 到齐时合并一次；连续块内帧继续零复制切片。 |

## 风险与边界

- Hub 降低广播后，设置页和 Compact 选中滚动仍必须在连接状态 / 工作区变化时更新。
- 焦点认领失败时不能乐观解除蒙版；需要按 RPC 结果保留或定向刷新 owner。
- Runtime reconnect / timeout 任务必须绑定 generation，旧 socket 的迟到回调不能影响新连接。
- daemon 热替换验证不得杀掉现有 daemon；只有专门验证 restart 功能时才使用本轮创建的可丢弃会话。
- 大内容优化不能降低现有 10 MiB 图片和 512 KiB diff 的安全上限；只改变准备与渲染方式。
- Swift RPC 取消目前只释放客户端 pending；远端 Git/search 子进程仍会运行到自身完成或现有超时。端到端取消需要单独确认协议变更。

## 修后严格审查确认项

- `CommandPalette.rank` 的多语句 `compactMap` 闭包缺少显式 `return`，当前 Desktop 目标无法编译。
- 握手截止时间在 `authed` 后取消，首份快照永久失败时连接会无限停留在 `connecting`。
- 永久配置错误不会安排重连，但工作台横幅仍显示“正在重连”。
- `SidebarView` 仍观察未使用的选中 Runtime，抵消逐服务器观察边界。
- 文件和 Git 面板切换同服务器终端时没有失效 session 上下文，失败时可保留旧终端内容。
- 文件、Git、端口模型持有非结构化任务，视图消失时没有统一取消入口。
- LocalRuntime 监控没有区分端口不可用、外部不健康服务和自有进程持续不健康。
- daemon 还需覆盖 `socket.write` 同步抛错，并补充帧头跨 socket chunk 的回归测试。

## 本轮明确不处理

- 不增加协议级 RPC cancel / deadline；保留已记录的远端工作继续执行风险。
- 不做文件树快照边界或渲染架构重构。

## 修后结论

- `CommandPalette.rank` 已恢复编译，Desktop 全量测试重新通过。
- readiness deadline 从创建 socket 起覆盖认证和首份快照；只有快照提交后才取消，超时会关闭当前连接并进入一次受控重连。
- 连接恢复状态已区分 `retrying` 和 `configurationError`；空入口、全部无效入口和无效公钥不会显示虚假重连动画。
- `SidebarView` 不再观察未使用的选中 Runtime，逐服务器 scope 成为宽侧边栏唯一内容观察边界。
- 文件和 Git 面板用 `(runtime, sessionId, generation)` 拒绝旧结果；切换会话立即清空旧内容。
- 文件、Git、端口面板在消失时统一取消模型任务；取消中的文件根目录可在重新出现后按相同 cwd 自动恢复加载。
- LocalRuntime 健康探针区分 `healthy / unavailable / unresponsive`；外部不健康端口不会触发 spawn，自有进程持续不健康会终止并按递增退避恢复。
- daemon 所有客户端写入统一捕获同步异常；FrameReader 覆盖 4 字节 header 分跨三个 chunk 的解析路径。
- FrameReader 对未完成单帧同时限制 64 MiB 和 8192 fragments；极小分片不能再用对象数量绕过内存边界。
- 端口面板缓存现在绑定 Runtime 身份和连接状态；runtime 自愈后会清掉旧 PID 并自动重载。
- LocalRuntime 按 `NSURLErrorDomain` 判断关闭端口；退避需连续健康才清零，owned process 退出只记账一次且不会被新进程覆盖。
- 与 managed Agent 恢复合并后，标题增量更新保留 `Session.agent`；`session.agentChanged` 继续触发完整快照。
- Agent 恢复请求保留调用方 deadline；默认 daemon 请求超时销毁 socket，只有 daemon 同样受 deadline 约束的恢复请求显式保持连接。
- Runtime E2E 的进程清理现在等待真实退出，临时目录删除不再与 daemon checkpoint 竞争。

## 仍存风险

- Swift RPC 取消仍只释放客户端 pending；远端 handler 和子进程不会被协议级取消。这是本轮明确排除的协议工作。
- 文件树仍使用顶层观察模型和递归行结构；大型展开目录的失效范围重构是本轮明确非目标。
- 协议级 RPC cancel / deadline 会改变协议和全部 handler 的取消契约，仍需用户明确决定后另行实现。

## 运行实例验证

- dev UI PID `1481`，runtime PID `25389`，daemon PID `1151`；`/Applications/Acro.app` PID `13192` 未触碰。
- 热替换与 runtime 自愈后，窗口显示“本机·就绪”，DokiLove 工作区和原终端会话仍存在。
- 命令面板搜索和键盘导航、工作区切换、文件 / Git / 端口面板已做真实 UI 验证。
- 未点击“在此设备继续使用”，未向终端输入内容；无效配置提示只由自动化测试覆盖，避免改写用户配置。

## 最终审查

- Desktop fresh 全量：74 项 XCTest、7 项 Swift Testing 全部通过；无剩余可复现 Critical / High / Medium。
- Protocol 13 项、Runtime 113 项与 Runtime E2E 全部通过；32 MiB / 16 KiB 分片、随机分片和 fragment 边界通过；无剩余可复现 Critical / High / Medium。
- 面板取消测试对底层 cancellation 的直接断言仍可加强，但当前实现已逐槽调用 `Task.cancel()`，不构成现存运行缺陷。

## 参考指针

- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/RuntimeHub.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/FileBrowserModel.swift`
- `apps/desktop-macos/Sources/GitPanelModel.swift`
- `apps/desktop-macos/Sources/LocalRuntime.swift`
- `apps/mobile/App.tsx` 的 `session.focusChanged` 增量消费
- PR #87 的未纳入项：RuntimeHub 广播放大和全量 reconcile
