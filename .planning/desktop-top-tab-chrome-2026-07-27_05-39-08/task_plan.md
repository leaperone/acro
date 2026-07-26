# 任务计划：desktop-top-tab-chrome

- 任务 ID：`desktop-top-tab-chrome-2026-07-27_05-39-08`
- 创建时间：`2026-07-27_05-39-08`

## 目标

让 Acro 的无标题栏窗口与 Bonsplit 顶部标签栏使用同一个 minimal presentation 语义，并用真实窗口测试证明标签贴顶和顶部边缘拖拽排序。

## 范围

- 显式配置 Bonsplit 使用 minimal 顶部模式。
- 扩展真实 `NSWindow + NSEvent` 回归，覆盖标签顶边几何和 minimal 模式重排。
- 核对宽、紧凑、隐藏侧栏的宿主行为。

## 非目标

- 不重写或复制 Bonsplit 拖拽算法；Acro vendor 与 cmux 当前版本一致。
- 不引入新的标签栏组件、动画系统或设置入口。
- 不改窗格布局协议和 runtime API。

## 关键约束

- Acro 固定使用 `.windowStyle(.hiddenTitleBar)`，Bonsplit presentation 不能继续依赖默认 `standard`。
- 标签选择和键盘操作保持即时，不增加动画。
- 用户拖拽标签时必须有插入位置反馈，松手后立即持久化。

## 修改路径

- `apps/desktop-macos/Sources/AcroApp.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- 必要时 `apps/desktop-macos/Tests/CompactSidebarTests.swift`

## 验证方式

- 两提交回归：先增加失败测试并取得 CI 红色，再实现 minimal host policy。
- 运行桌面针对性测试、全部 Desktop 测试、`pnpm check`、`pnpm build` 和 CI。
- 热替换当前签名 dev app；若 Computer Use 仍不可用，只记录未做真实 UI 操作，不重复尝试。

## 验收标准

- [ ] Acro 启动后 Bonsplit 读取到 `workspacePresentationMode=minimal`。
- [ ] 真实窗口中标签栏顶边与内容顶边对齐，无额外空区。
- [ ] minimal 模式下标签拖拽可重排并持久化。
- [ ] 标签后方空白 chrome 采用 minimal 的窗口拖动/双击语义，按钮按 minimal 规则显示。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 不改 vendored Bonsplit | 与 cmux `aac23518` 的 TabBarView、TabItemView、metrics 逐字一致 |
| Acro 固定 minimal presentation | App 本身固定 hiddenTitleBar；继续让 Bonsplit 默认 standard 会让顶部空白 chrome、按钮和标题栏交互语义冲突 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Computer Use runtime 不可用 | 1 | 按仓库规则只检查一次，改用源码、真实窗口测试和当前进程状态作为证据 |
| 新 worktree 缺少 GhosttyKit 头文件 | 1 | 运行项目 `setup-ghostty.sh` 后恢复测试构建 |
| 合成事件从扩展命中区最顶部拖拽会进入 AppKit 模态拖动 | 1 | 不把测试基础设施限制当业务失败；真实重排继续使用可重复的标签视觉中心，顶边由独立 frame 断言覆盖 |
