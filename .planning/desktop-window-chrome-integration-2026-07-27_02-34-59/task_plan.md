# 任务计划：desktop-window-chrome-integration

- 任务 ID：`desktop-window-chrome-integration-2026-07-27_02-34-59`
- 创建时间：`2026-07-27_02-34-59`

## 目标

在不改变现有顶部垂直布局的前提下，确认并修复 Acro 与 cmux 顶部标签栏的真实 UIUX 差距。

## 范围

- 从 NSWindow 读取原生标题栏高度、content safe-area top 和全屏状态。
- 只对终端与右侧栏所在的 HSplitView 抵消实际标题栏安全区；左侧栏标题行保持不变。
- 回归验证 wide/compact/hidden、普通窗口与全屏。

## 非目标

- 不修改 Bonsplit 内部标签、拖拽、滚动或重排算法。
- 不引入 cmux 的浏览器按钮、自定义命令系统、完整主题配置或新设置项。
- 不发布新 Beta；发布需用户在新改动合并后再次明确要求。

## 关键约束

- Bonsplit controller 仍是 pane/tab 运行态唯一真相源。
- 不增加第二套窗口拖动手势；复用 Bonsplit minimal 模式的原生实现。
- 保留 daemon、PTY、TerminalSurfaceCache、文件拖放和现有三态侧栏。
- 主 checkout 的无关 dirty 内容不修改。

## 修改路径

- `apps/desktop-macos/Sources/WorkbenchView.swift`
- `apps/desktop-macos/Tests/CompactSidebarTests.swift`

## 验证方式

- 针对性 Swift Testing：窗口全屏与侧栏状态共同决定交通灯留白。
- Acro Desktop 全量测试与 debug/release build。
- Bonsplit 既有测试确认 minimal 模式窗口拖动和 action lane 行为。
- 打包并热替换本机 dev UI/runtime，保留 daemon；若 UI 自动化不可用，明确记录未做真实交互验收。

## 验收标准

- 顶部不得新增任何垂直空区。
- 用户指出的交互差距得到真实窗口验证。
- 自动化测试和构建通过，无标签重排行为回归。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 不使用全局 `workspacePresentationMode = minimal` | 真实运行实例出现顶部垂直空区，说明 Acro 缺少 cmux 对应的宿主标题栏布局 |
| 不提交未经过真实窗口确认的宿主能力拆分 | 第二次尝试仍被用户确认存在空区，源码推断不足以证明视觉正确 |
| 复用 cmux 的动态安全区抵消公式 | 截图与 cmux 源码共同证明空区来自 WindowGroup hosting safe area；固定负数会在全屏和不同系统标题栏高度下失效 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| Orca runtime 未启动，无法做 Computer Use | 1 | 按项目规则停止重试；保留真实 UI 验证边界 |
| `.tmp/cmux` pull 因 DNS 无法解析 github.com | 1 | 参考仓保持干净；用当前 cmux HEAD，并逐字节核对相关 Bonsplit 文件 |
| 删除旧拖窗视图后 SidebarView/CompactSidebarView 编译失败 | 1 | 确认手柄仍服务侧栏标题区；恢复侧栏专用手柄，终端顶部仍改走 Bonsplit |
| 全局 minimal 模式造成顶部空区 | 1 | 立即撤回、删除 defaults、热替换回原版 beta.19 |
| 独立 hover/drag 宿主配置仍出现顶部空区 | 1 | 全部代码撤回，本机切回主仓原版 beta.19；等待局部视觉证据 |
