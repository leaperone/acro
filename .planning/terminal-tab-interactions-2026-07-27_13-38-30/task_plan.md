# 任务计划：terminal-tab-interactions

- 任务 ID：`terminal-tab-interactions-2026-07-27_13-38-30`
- 创建时间：`2026-07-27_13-38-30`

## 目标

恢复顶部 Terminal 标签栏的完整 cmux/Bonsplit 交互：普通点击切换、同窗格插入重排、跨窗格移动、边缘拖拽分屏、右侧新建/分屏按钮和布局持久化。

## 范围

- 对照当前 Acro、Beta.17 改动和 `.tmp/cmux` 的 Bonsplit 实现定位共同根因。
- 添加可执行的 AppKit 行为回归测试，并修复真实事件路径。
- 保留现有 Terminal surface 生命周期、文件拖放、快捷键和侧边栏行为。

## 非目标

- 不重新设计标签栏视觉。
- 不修改侧边栏、终端 daemon 或协议。
- 不使用 Computer Use 代替源码和行为测试。

## 关键约束

- 复用 vendored Bonsplit/cmux 的单一交互链，不再叠加自定义拖拽层。
- 回归测试先单独提交失败测试，再提交修复。
- 保留主仓无关 dirty 文件和 daemon 进程。

## 修改路径

- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- 根据失败测试定位，最小修改 `apps/desktop-macos/Vendor/bonsplit/` 或 Acro 的 Bonsplit 集成层。

## 验证方式

- `swift test --package-path apps/desktop-macos --filter TerminalPanesInteractionTests`
- `swift test --package-path apps/desktop-macos`
- `pnpm check` 与桌面 app 打包。
- 热替换 dev UI/runtime 时保留 daemon PID。

## 验收标准

- 点击任意非激活标签会切换并持久化选择。
- 标签可同窗格重排、跨窗格移动、拖到边缘分屏。
- 右侧新建、向右分屏、向下分屏按钮均可执行。
- divider 调整和既有布局持久化不回归。

## 未确认事项

没有则写“无”。

- 是否发布新 Beta：当前用户要求修复与仔细核查，完成合并后根据本轮连续发版上下文执行 Beta 发布前再复核。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 以 Bonsplit 公开交互和 AppKit 真实鼠标事件为测试边界 | 现有 controller 单元测试无法证明 hit-testing 与按钮命中 |
| 修共同命中/交互根因 | 用户报告的点击、拖拽、分屏按钮同时失效，不应逐入口打补丁 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 现有筛选测试显示 XCTest 0 项 | 1 | Swift Testing 随后实际执行 43 项并通过；记录为框架输出，不是漏跑 |
