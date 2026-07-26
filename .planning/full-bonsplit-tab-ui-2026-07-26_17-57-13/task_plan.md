# 任务计划：full-bonsplit-tab-ui

- 任务 ID：`full-bonsplit-tab-ui-2026-07-26_17-57-13`
- 创建时间：`2026-07-26_17-57-13`

## 目标

用 cmux 当前使用的完整 Bonsplit `48643102` 替换 Acro 自研的 pane/tab UI 与拖拽链，让顶部标签栏、分屏、重排、滚动、窗口拖动隔离和拖拽生命周期达到 cmux 的真实交互质量。

## 范围

- Vendor 最新完整 Bonsplit，并保留 MIT 许可证与来源声明。
- 每个 workspace 建立一个 Bonsplit controller，作为运行期 pane/tab UI 与交互唯一真相源。
- 用最小桥接层在现有 `WorkspaceTerminalLayout` 持久化快照与 Bonsplit controller 之间恢复/回写。
- 接入 Acro 的终端内容、创建/关闭、焦点、文件拖放、快捷键、布局同步和多服务器隔离。
- 删除自研标签栏、分屏渲染和重复 pane/tab drop 链。

## 非目标

- 不改变 Runtime RPC、Workspace/Session 数据模型和服务端布局协议。
- 不复制 cmux Workspace 的业务层、侧栏、浏览器或 action lane 产品功能。
- 不修改或清理旧的 dirty `fix/desktop-use-full-bonsplit` worktree。
- 不在 Bonsplit 上增加 Acro 专属视觉分叉，优先使用其公开配置和 delegate。

## 关键约束

- 用户已明确授权完整架构替换。
- 以最新 cmux `f79e3d86` / Bonsplit `48643102` 为基线，不使用旧 pin `10563e2`。
- 运行期不得保留两套 pane/tab 可变真相源；持久化快照只负责恢复与同步。
- 保留 beta.17/18 已有的终端文件拖放、三态侧栏、布局去抖、reconcile、后台 surface 点击保护和 daemon 会话续存。
- 标签重排不添加 spring；对齐 cmux 的即时插入线、mouse-up commit 和无动画稳定感。

## 修改路径

- `apps/desktop-macos/Vendor/bonsplit/**`
- `apps/desktop-macos/Vendor/NOTICE.md`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/scripts/package-app.sh`

## 验证方式

- Bonsplit 自身完整测试。
- Acro Desktop 针对布局恢复、同 pane 重排、跨 pane、分屏、焦点、文件拖放和生命周期的集成测试。
- `swift test --package-path apps/desktop-macos`、Release 打包、`pnpm check`、`pnpm build`。
- 本机热替换时保留 daemon，真实验证顶部标签拖拽、滚动、末尾落点、窗口拖动和会话重连；若 UI 自动化权限不可用则明确记录。
- preflight、PR、squash merge；按用户本轮前置指令发布下一版 desktop beta。

## 验收标准

- 顶部标签宽度、选中/hover/关闭槽、拖拽 preview、4pt 阈值、中点插入、no-op 抑制、末尾空白落点和溢出滚动行为与 cmux/Bonsplit 一致。
- 标签可在同 pane 排序、跨 pane 精确插入、拖到内容区中心移动、拖到边缘分屏。
- 拖拽取消、切 workspace、无效 payload 后不残留插入线或拖拽状态。
- 快捷键、关闭、创建、焦点、文件拖放和布局持久化不回归。
- 重启 UI/runtime 后 daemon 会话保留，布局可恢复。

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
| 完整 vendor Bonsplit `48643102` | 当前 shim 只有 93 行类型外形，无法提供 cmux 的真实交互、几何和生命周期 |
| Bonsplit controller 是运行期唯一真相源 | 双树同步是现有漂移和残缺交互的根因；快照只用于持久化与多端同步 |
| 从最新 main 新建 worktree 重做 | 旧 full-bonsplit worktree 落后 53 个提交且 dirty，直接覆盖会丢 beta.17/18 修复 |
| 复用旧 `TerminalPaneController` 的算法，不整文件搬运 | 旧桥接有价值，但其 sidebar、file drop、reconcile 接口已过时 |
| 新终端先写入 controller/layout，再刷新 Runtime | 避免 `session.create → refresh → reconcile` 抢先 adopt，造成重复标签或丢失分屏目标 |
| 文件拖放统一经过 Workbench 授权门 | Bonsplit overlay 与 Ghostty AppKit 直达路径都必须校验认证、workspace membership 和设备占用 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `cmux git pull` 受本机 DNS/HTTPS 阻断 | 3 | 通过 GitHub SSH 443 完成 fast-forward；Bonsplit 使用 shallow submodule checkout |
