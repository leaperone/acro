# 执行进度：avoid-ghostty-app-data-access

- 任务 ID：`avoid-ghostty-app-data-access-2026-07-27_04-16-15`
- 创建时间：`2026-07-27_04-16-15`
- 当前状态：`complete`

## 已完成

- 核对当前进程、签名、TCC 日志和 Ghostty 配置调用链。
- 排除双开 Acro 和启动时 runtime 自动扫描 home/Containers。
- 确认 Ghostty 默认加载器会读取另一个 bundle 的 Application Support。
- 用显式 XDG 配置路径替换 Ghostty 默认加载器。
- 增加自定义 XDG 与默认 `~/.config` 路径测试。
- reviewer 未发现 critical/high；修复了相对 `XDG_CONFIG_HOME` 可能传入 Ghostty C API 的 medium 风险。

## 进行中

- 无。

## 修改文件

- `.planning/avoid-ghostty-app-data-access-2026-07-27_04-16-15/*`
- `apps/desktop-macos/Sources/Ghostty.swift`
- `apps/desktop-macos/Tests/GhosttyConfigTests.swift`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| TCC 现场日志 | 连续请求为 `SystemPolicyAppData`，accessing binaries 为 bash/du/rm | 已确认 |
| 当前稳定签名实例 | 03:54 启动后无新的 App Data 请求 | 已确认 |
| Ghostty 源码 | 默认加载器额外探测 `com.mitchellh.ghostty` Application Support | 已确认 |
| `GhosttyConfigTests` | 1 XCTest | 通过 |
| Desktop 全量测试 | 80 XCTest + 20 Swift Testing | 通过 |
| `pnpm check` | protocol/runtime/cli/mobile 全部通过 | 通过 |
| `pnpm build` | 通过，仅既有 `import.meta` 警告 | 通过 |
| 源码调用检查 | 无 `ghostty_config_load_default_files` 调用 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 新 worktree 缺少 `GhosttyKit/ghostty.h` | 1 | 使用仓库固定版本和校验哈希的 setup 脚本补齐 |
| actor-isolated test 编译错误 | 1 | 路径 helper 是纯函数，标为 `nonisolated` 后测试通过 |
