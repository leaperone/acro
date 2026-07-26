# 执行进度：tab-drag-input-chain

- 任务 ID：`tab-drag-input-chain-2026-07-27_03-37-55`
- 创建时间：`2026-07-27_03-37-55`
- 当前状态：`complete`

## 已完成

- 更新 cmux reference，并确认 Bonsplit gitlink 未变化。
- 核对 Acro 配置、delegate 持久化和现有测试缺口。
- Computer Use 检查一次，Orca runtime 不可用。
- 新增真实 NSWindow/NSHostingView/NSEvent 标签拖拽测试。
- 修正测试最初把整条标签栏背景算成第四个标签的问题。
- 在当前 safe-area 补偿和禁用窗口隐式拖动条件下验证重排与持久化通过。

## 进行中

- 无。

## 修改文件

- `.planning/tab-drag-input-chain-2026-07-27_03-37-55/*`
- 预计修改 `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Acro/cmux Bonsplit 版本 | 均为 `48643102` | 通过 |
| 配置检查 | 重排与跨窗格移动均开启 | 通过 |
| 真实桌面自动化 | Orca runtime 不可用 | 未执行 |
| 真实 AppKit 鼠标链 | down/drag/up 将首标签移动到末尾并持久化 | 通过 |
| Acro Desktop 全量测试 | 79 XCTest 与全部 Swift Testing 通过 | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 通过 | 通过 |
| `pnpm build` | workspace build 通过，仅既有 `import.meta` 警告 | 通过 |

## 交付前收敛

- 最终产品代码未改动；当前实现已经具备真实标签拖拽排序。
- 新测试覆盖 Acro 宿主窗口、safe-area 补偿、真实标签 frame、NSEvent monitor、Bonsplit drop 和布局持久化。
- 没有用控制器 API 或硬编码模型变更冒充指针验收。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Orca runtime unavailable | 1 | 停止重试，改用 AppKit 真实事件测试 |
| 首次测试识别到 4 个 hit region | 1 | 排除覆盖整条标签栏的背景 provider，只使用真实 tab item frame |
| 新 worktree 缺少 `ghostty.h` | 1 | 运行仓库 `setup-ghostty.sh` 后测试正常编译 |
