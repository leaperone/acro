# 调研与结论：avoid-ghostty-app-data-access

- 任务 ID：`avoid-ghostty-app-data-access-2026-07-27_04-16-15`
- 创建时间：`2026-07-27_04-16-15`

## 需求事实

- 用户遇到 macOS “Would like to access data from other apps” 频繁弹窗。
- TCC 日志证明连续弹窗由 Acro 终端内 `bash`、`du`、`rm` 访问受保护目录触发，系统按 responsible app 显示为 Acro。
- 当前固定 Developer ID 签名实例启动后没有新的 `SystemPolicyAppData` 请求，频繁重复授权已停止。

## 真实调用链

- `AcroApp.onAppear` 初始化 `Ghostty.shared`。
- `Ghostty.init` 与 `reloadConfig` 都调用 `makeConfig()`。
- `makeConfig()` 调用 `ghostty_config_load_default_files`。
- GhosttyKit 在 macOS 上除 XDG 文件外，还会探测 `~/Library/Application Support/com.mitchellh.ghostty/config*`。

## 调研结论

- Acro 自身存在不必要的跨 App 数据访问：产品只承诺读取 `~/.config/ghostty`，却使用了 Ghostty.app 的默认加载器。
- 共享根因入口只有 `Ghostty.makeConfig()`；修改调用方会重复且遗漏热重载路径。
- 显式加载两个 XDG 文件即可保留 legacy/new 配置顺序和 recursive include 语义。
- 路径 helper 只接受非空绝对 `XDG_CONFIG_HOME`；缺失、空值或相对路径时回退 `~/.config`，避免把 Ghostty C API 不接受的相对路径传入加载器。
- 最终源码已经没有 `ghostty_config_load_default_files` 调用。

## 技术决策

| 决策 | 证据 |
|---|---|
| 移除默认文件加载器 | Ghostty 源码明确在 macOS 无条件探测 Application Support |
| 保留 XDG legacy/new 两个文件 | 当前设置文案和注释承诺兼容 `~/.config/ghostty/config`，Ghostty 默认顺序也是 legacy 后 new |
| 拒绝相对 `XDG_CONFIG_HOME` | Ghostty `Config.loadFile` 要求绝对路径，相对值可能触发断言 |

## 风险与边界

- 用户 Ghostty 配置中的 `config-file` include 仍可指向任意路径；这是用户显式配置，不在本轮限制。
- 终端/Agent 自身访问受保护目录时，macOS 仍可能向 responsible app 请求权限；本轮只消除 Acro 自己的无关访问。

## 参考指针

- `apps/desktop-macos/Sources/Ghostty.swift:81-95`
- `apps/desktop-macos/Tests/GhosttyConfigTests.swift`
- `.tmp/ghostty/src/config/Config.zig:4064-4120`
- `.tmp/ghostty/src/config/file_load.zig:52-86`
