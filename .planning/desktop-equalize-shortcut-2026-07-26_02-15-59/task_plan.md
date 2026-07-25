# 任务计划：desktop-equalize-shortcut

- 任务 ID：`desktop-equalize-shortcut-2026-07-26_02-15-59`
- 创建时间：`2026-07-26_02-15-59`

## 目标

让 Acro Desktop 使用与 cmux 一致的 `Control + Command + =` 默认快捷键，均分当前 Terminal 标签页中的全部分屏窗格。

## 范围

- 修改 `equalizeSplits` 的共享默认快捷键。
- 增加真实 `NSEvent` 匹配测试，覆盖默认键和显示文本。
- 验证菜单、设置页、终端拦截和 Workbench 动作继续复用同一入口。

## 非目标

- 不修改已经存在的均分算法和分屏布局模型。
- 不新增第二套动作、菜单或快捷键监听。
- 不覆盖用户在 `~/.config/acro/keybindings.json` 中的自定义绑定。
- 不处理归属其他任务的 dirty worktree。

## 关键约束

- `.tmp/cmux` 只读，仅用于对照动作、默认键和算法语义。
- 主 checkout 的无关改动必须保留；全部写入独立 worktree。
- 使用现有 `ShortcutSettings` 统一入口，保持菜单、终端和设置页一致。

## 修改路径

- `apps/desktop-macos/Sources/ShortcutSettings.swift`
- `apps/desktop-macos/Tests/ShortcutSettingsTests.swift`
- 本任务三份 planning 文件

## 验证方式

- 先在未修复代码上运行新增测试，证明旧默认键会失败。
- 运行桌面端目标测试和构建。
- 打包本机 dev app，在保留 daemon/PTY 的前提下热替换 UI + runtime，并真实按键验收。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成 Git 收尾

## 决策

| 决策 | 理由 |
|---|---|
| 只改共享默认值 | Acro 已有完整 `equalizeSplits` 动作、路由、菜单、设置项和布局算法；根因只是默认修饰键与 cmux 不一致。 |
| 增加一条事件匹配测试 | 它能覆盖实际 keyCode、修饰键、应用路由和快捷键显示，且不重复测试未改动的布局算法。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| worktree 脚本刷新远端 base 时网络请求未返回 | 1 | 使用已核对与 `main` 相同的本地 `origin/main` commit SHA 作为固定 base，再由同一脚本成功创建 worktree。 |
| 首次运行测试缺少 `GhosttyKit/ghostty.h` | 1 | 运行仓库自带 `scripts/setup-ghostty.sh`，校验并安装固定版本 Ghostty 构建依赖。 |
| Computer Use 无法读取 Acro 隐藏标题栏窗口 | 2 | 两套 Computer Use 均返回无可用 Accessibility/CGWindow；停止重试，保留自动化事件测试、打包产物、运行进程和 runtime 健康证据，并明确未完成截图级 UI 验证。 |
