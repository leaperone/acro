# 调研与结论：stable-helper-identity

- 任务 ID：`stable-helper-identity-2026-07-27_05-00-57`
- 创建时间：`2026-07-27_05-00-57`

## 需求事实

- 当前 helper PID 1068 由 LaunchAgent `one.leaper.acro.helper` 启动。
- helper 当前 Accessibility 与 Screen Recording 均为 false。
- 用户之前遇到频繁权限请求，稳定授权身份是 Computer Use 可用性的基础。

## 真实调用链

- `install-launchagents.sh` 每次执行 `swift build -c release`。
- helper plist 直接指向仓库 `apps/helper-macos/.build/release/acro-helper`。
- Swift 链接器只产生 ad-hoc 签名，identifier 为 `acro-helper`，Team ID 为空，designated requirement 是当前 cdhash。
- runtime 只连接 `~/.acro/helper.sock`，不负责 spawn helper，因此 helper 可独立安装和重启。

## 调研结论

- 重编译、编译器变化、仓库迁移或 worktree 切换都会改变当前 helper 的代码身份或路径。
- 使用 Developer ID 签名并显式固定 identifier 后，designated requirement 可绑定 Apple anchor、Team ID 和 identifier，不再绑定 cdhash。
- LaunchAgent 还必须指向固定安装路径，不能继续运行仓库构建目录。

## 技术决策

| 决策 | 证据 |
|---|---|
| 安装到 `~/.acro/bin/acro-helper` | 当前 state/socket/log 已集中在 `~/.acro`，固定目录不随 checkout 变化 |
| 原子替换签名后的 staged 文件 | 失败时保留旧 helper，运行中的进程也不受半写文件影响 |
| 自动检测唯一 Developer ID，允许显式覆盖 | 当前机器只有一个可用 Developer ID；多证书时必须由用户明确选择 |

## 风险与边界

- 第一次从 ad-hoc 迁移到正式身份时，macOS 可能要求重新授权一次。
- release 尚未分发 helper；本轮只修 Mac mini 的仓库安装链，不改变桌面安装包结构。
- 本机真实 Developer ID 签名结果为 identifier `one.leaper.acro.helper`、Team `5UAHRS482C`、hardened runtime；designated requirement 绑定 Apple anchor、Developer ID、Team 与 identifier，不含 cdhash。
- 仅拒绝 ad-hoc 不足以保证身份稳定；Apple Development 证书也能通过 `codesign --verify`，但 requirement 会绑定具体开发证书。安装脚本必须校验实际 Authority、Team、identifier 与 Developer ID OID。

## 参考指针

- `scripts/install-launchagents.sh:34-63`
- `apps/helper-macos/Package.swift`
- `apps/helper-macos/Sources/main.swift:55-70`
- `apps/runtime/src/computer.ts:1-80`
