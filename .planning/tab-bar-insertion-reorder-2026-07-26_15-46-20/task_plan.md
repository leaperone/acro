# 任务计划：tab-bar-insertion-reorder

- 任务 ID：`tab-bar-insertion-reorder-2026-07-26_15-46-20`
- 创建时间：`2026-07-26_15-46-20`

## 目标

让顶部终端标签支持明确、稳定的标签间拖拽插入排序，并保持现有跨窗格移动、分屏、选择和布局持久化行为。

## 范围

- 修正 `PaneTabBar` 的同栏拖拽落点。
- 复用现有 `WorkspaceTerminalLayout.moveTab` 顺序模型和持久化链路。
- 增加可执行回归验证，覆盖标签左右半区到插入下标的解析和现有排序算法。

## 非目标

- 不引入 Bonsplit 私有实现或新依赖。
- 不改窗格拖拽分屏、跨窗格移动、标签文案和视觉尺寸。
- 不改 Runtime 布局协议和多设备 last-writer-wins 契约。

## 关键约束

- 修根因，不在每个调用方补保护。
- 保留窗口空白拖动区，不让标签拖拽带动窗口。
- 参考目录只读；GitHub DNS 不可用时明确记录未刷新。

## 修改路径

- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Tests/` 中最小行为测试

## 验证方式

- `swift test --package-path apps/desktop-macos` 的针对性与完整测试。
- 打包并热替换本机 dev app，在真实 UI 中验证三标签双向排序、拖到末尾和窗口不位移。
- `git diff --check` 与 preflight。

## 验收标准

- 拖到目标标签左半区时插在目标前，右半区时插在目标后。
- 同栏向前、向后和末尾排序结果正确，选择仍跟随被拖标签。
- 跨窗格移动和窗格分屏不回归。
- 重启后顺序仍由现有布局持久化恢复。

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
| 在现有 SwiftUI 标签上叠加左右两个插入区 | Orca 使用目标中点 before / after 语义；现有状态层已经正确处理插入下标，无需新增模型 |
| 移除覆盖整条标签栏的末尾 drop 接收器 | 它与子标签 drop 区域重叠，可能先吞掉拖拽；最后标签右半区已自然表达末尾 |
| 不移植 cmux Bonsplit | Acro 只 vendored 了 CmuxPanes 和自写 Bonsplit shim，没有上游私有标签 UI 实现 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `git pull` cmux / Orca 失败：无法解析 github.com | 2 | 保留干净的本地快照只读对照，交付中明确未刷新 |
