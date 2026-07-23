# 任务计划：desktop-performance-robustness

- 任务 ID：`desktop-performance-robustness-2026-07-23_14-19-19`
- 创建时间：`2026-07-23_14-19-19`

## 目标

消除 Acro 桌面端日常操作中的可证明卡顿、陈旧状态和无出口等待。让 Runtime 事件只更新必要状态，让面板请求绑定正确服务器并可取消，让连接与本机服务失败后可以恢复，并避免主线程重复构造昂贵内容。

## 范围

- [x] 核对当前 main、真实 dev 窗口、运行进程、全部调用方和现有测试。
- [x] 切断 Runtime 普通事件到全量四 RPC 刷新、Hub 全局广播和全量布局对账的放大链。
- [x] 让文件、Git、端口面板按服务器和请求代次持有状态，取消过期工作并拒绝旧响应。
- [x] 为连接握手、本机 Runtime 退出和 daemon 超时补齐明确的恢复出口。
- [x] 缓存命令面板搜索语料，并把大图片 / 大 diff 的准备移出 SwiftUI 主线程热路径。
- [x] 约束 daemon 大响应发送队列，并消除 FrameReader 分片累计复制。
- [x] 修复修后审查确认的 Desktop 编译、连接就绪、面板会话边界和本机 Runtime 自愈问题。
- [x] 补齐 daemon 同步写异常与 FrameReader header 跨 chunk 回归测试。
- [x] 完成针对性测试与全量构建验证。

## 非目标

- 不改变 Acro 的 Runtime / thin client 架构和协议对外契约。
- 不实现 remote-development-surfaces 规划中的新 Browser、Simulator 或 Computer Surface。
- 不重做桌面视觉，不增加新依赖，不顺手改移动端。
- 不实现协议级 RPC cancel / deadline，不重构文件树架构。
- 不把本机 dev 热替换冒充正式发布；正式发布仍走独立 release 流程。
- 不清理主 checkout 中用户现有的 `.agents/skills/release/SKILL.md` 修改或归属不明 worktree。

## 关键约束

- `packages/protocol` 仍是协议唯一真源；能用现有事件 payload 修复的行为不扩协议。
- 服务端仍是会话、工作区和控制权真相源；客户端只做增量投影和故障恢复。
- 修根因：请求所有权必须覆盖 runtime identity、路径和代次，不能只在按钮上加禁用态。
- 连接 ready 必须同时满足认证成功和首份完整快照；永久配置错误不能伪装成自动重连。
- 文件和 Git 面板的请求所有权必须包含 session 上下文；视图消失必须取消模型内部任务。
- LocalRuntime 只能终止自己启动的进程；外部端口占用不能触发反复 spawn。
- 终端 daemon 必须保留；日常桌面 / runtime 热替换不能结束已有 PTY。
- 每个非平凡分支留下最小可运行回归测试。

## 修改路径

- `.planning/desktop-performance-robustness-2026-07-23_14-19-19/*`
- `apps/desktop-macos/Sources/RuntimeConnection.swift`
- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Sources/RuntimeHub.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Sources/SidebarView.swift`
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
- `apps/desktop-macos/Sources/FileBrowserModel.swift`
- `apps/desktop-macos/Sources/FileBrowserView.swift`
- `apps/desktop-macos/Sources/GitPanelModel.swift`
- `apps/desktop-macos/Sources/GitPanelView.swift`
- `apps/desktop-macos/Sources/PortsPanelView.swift`
- `apps/desktop-macos/Sources/LocalRuntime.swift`
- `apps/desktop-macos/Sources/E2ee.swift`
- `apps/desktop-macos/Sources/ServerDirectory.swift`
- `apps/desktop-macos/Sources/SettingsView.swift`
- `apps/desktop-macos/Sources/CommandPalette.swift`
- 对应 `apps/desktop-macos/Tests/*`
- `apps/runtime/src/daemon/client.ts`
- `apps/runtime/src/daemon/backpressure.ts`
- `apps/runtime/src/daemon/daemon.ts`
- `apps/runtime/src/daemon/wire.ts`
- `apps/runtime/src/index.ts`
- `apps/runtime/scripts/e2e.ts`
- 对应 `apps/runtime/src/daemon/*.test.ts`

## 验证方式

- 针对性 Swift tests：事件增量更新、Hub 失效边界、请求取消 / 代次、连接超时与恢复、daemon 重启恢复。
- `swift test --package-path apps/desktop-macos`
- `pnpm --filter @acro/runtime test`
- `pnpm --filter @acro/runtime check`
- `pnpm --filter @acro/runtime e2e`
- `pnpm check`
- `git diff --check`
- 打包 dev app，保留 daemon 热替换 UI / runtime，并验证本机恢复与会话保留。
- 完成 commit、push、PR、preflight、merge 和任务分支清理；正式发布不在本任务范围。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成 dev app 打包、热替换、真实 UI 和 Runtime 自愈验证

## 决策

| 决策 | 理由 |
|---|---|
| 先处理事件刷新与全局失效 | 当前一个焦点事件可触发全量刷新，调用方还会再刷新一次，是最直接的日常卡顿放大器。 |
| 面板状态键包含服务器身份 | 相同 sessionId 或路径在不同 Runtime 上不是同一资源。 |
| 连接失败统一走同一状态转换 | guard 直接返回会留下永久连接中 / 未连接状态，必须进入可重试出口。 |
| 不新增依赖 | 现有 Combine、Swift concurrency、AppKit 和 vendored 搜索组件足够。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 主 checkout 有无关 dirty 文件 | 1 | 创建 `fix/desktop-performance-robustness` 独立 worktree，原改动保持不动。 |
