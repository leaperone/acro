# 执行进度：bonsplit-tab-accessibility

- 任务 ID：`bonsplit-tab-accessibility-2026-07-27_18-16-26`
- 创建时间：`2026-07-27_18-16-26`
- 当前状态：`in_progress`

## 已完成

- 检查正式安装 Beta.31 的 Wide、Compact、Hidden 三种侧栏和双窗格顶部栏。
- 用真实 Accessibility tree 确认标签、关闭与 split action 的名称缺失。
- 对照 Acro、Vendored Bonsplit 与 cmux 源码，确认共享根因与影响范围。
- 创建独立 worktree `fix/bonsplit-tab-accessibility` 并校验项目基线。
- 尝试用 `NSHostingView + NSWindow` 读取 AX tree，确认同进程只能看到空 group，不能作为有效回归测试。
- 删除无论修复与否都会失败的假测试，保留正式应用真实 AX tree为硬验收。

## 进行中

- 实现共享根修与本地化。

## 修改文件

- `.planning/bonsplit-tab-accessibility-2026-07-27_18-16-26/`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Beta.31 真实截图 | Wide/Compact/Hidden 稳定布局正常 | 通过 |
| Beta.31 Accessibility tree | 标签、close、普通 split actions 缺少明确名称 | 已复现 |
| Acro/cmux/Bonsplit 源码对照 | 根因位于 Bonsplit 最终组合层，cmux 同样不完整 | 通过 |
| 同进程 AX harness | 仅返回空 group，无法区分修复前后 | 不适用，已删除假测试 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 紧凑侧栏截图空白 | 1 | 等待动画结束后复查，确认稳定态正确 |
| AX 单测无论修复与否都会失败 | 1 | 删除假测试，改用正式候选应用的真实系统 AX tree |
