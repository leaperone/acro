# 任务计划：avoid-ghostty-app-data-access

- 任务 ID：`avoid-ghostty-app-data-access-2026-07-27_04-16-15`
- 创建时间：`2026-07-27_04-16-15`

## 目标

让 Acro 加载终端配置时只读取产品明确支持的 XDG Ghostty 配置和 Acro 自有配置，不再访问 Ghostty.app 的 Application Support 数据目录。

## 范围

- 替换 `ghostty_config_load_default_files`，显式加载 XDG 下的 `ghostty/config` 与 `ghostty/config.ghostty`。
- 增加配置路径解析回归测试。

## 非目标

- 不改变终端子进程的 macOS responsible-process 归因。
- 不新增 TCC entitlement，不清空或修改系统权限数据库。
- 不重构 runtime/daemon 为 LaunchAgent；这属于架构转向。

## 关键约束

- 保持 legacy `config` 先于 `config.ghostty` 的加载顺序。
- 尊重 `XDG_CONFIG_HOME`；未设置时回退到 `~/.config`。
- Acro 自有配置继续最后加载并覆盖用户 Ghostty 配置。

## 修改路径

- `apps/desktop-macos/Sources/Ghostty.swift`
- `apps/desktop-macos/Tests/GhosttyConfigTests.swift`

## 验证方式

- 定向 Swift Testing。
- Desktop 全量测试、`pnpm check`、`pnpm build`。
- 源码断言不再调用 `ghostty_config_load_default_files`。

## 验收标准

- App 启动和外观热重载不再探测 `~/Library/Application Support/com.mitchellh.ghostty`。
- `~/.config/ghostty/config` 与 `config.ghostty` 仍按原顺序加载。
- 自定义 `XDG_CONFIG_HOME` 生效。

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
| 显式加载 XDG 文件 | 保留 Acro 已承诺的兼容范围，同时避开 Ghostty.app 的受保护数据目录 |
| 不增加权限 | Acro 不需要读取另一个 App 的 Application Support，减少权限面才是根治 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 新 worktree 缺少未入库 GhosttyKit 产物 | 1 | 运行仓库 `setup-ghostty.sh` 后恢复构建 |
| 测试从非 MainActor 调用路径 helper | 1 | 将纯路径函数标为 `nonisolated` |
