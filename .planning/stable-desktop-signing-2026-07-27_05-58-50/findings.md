# 调研与结论：stable-desktop-signing

- 任务 ID：`stable-desktop-signing-2026-07-27_05-58-50`
- 创建时间：`2026-07-27_05-58-50`

## 需求事实

- 用户反馈 Acro dev 频繁出现 macOS “Would like to access data from other apps”。
- 当前只有一套 Acro：UI PID 8941、runtime PID 9206、daemon PID 1151、helper PID 54005。
- 当前 UI/helper 已是 Team `5UAHRS482C` 的稳定 Developer ID 身份。

## 真实调用链

- Acro UI 启动 runtime，runtime 连接 detached daemon，daemon 通过 node-pty 启动 shell/Agent。
- shell 中的 `du`、`rm`、`find` 访问受保护的 `~/Library` 时，TCC 将 responsible app 归因到 `one.leaper.acro.desktop`。
- `package-app.sh` 未设置 `ACRO_SIGN_IDENTITY` 时默认 `-`，本地热替换因此可能生成每次 CDHash 不同的 ad-hoc App。

## 调研结论

- 03:08–03:13 的批量弹窗来自终端子进程访问受保护 App Data，不是 helper 主动请求。
- 旧 TCC 记录绑定 ad-hoc CDHash；当前 Developer ID requirement 无法匹配旧记录。
- Acro 自身状态已在 `~/.acro`，不需要照搬 cmux 的状态目录迁移。
- Ghostty 默认 Application Support 探测已由 PR #127 移除；本轮不重复修改。

## 技术决策

| 决策 | 证据 |
|---|---|
| 在打包入口禁止隐式 ad-hoc | 一处守门覆盖所有本地 package 调用，避免每个调用方各自补丁。 |
| 不新增 entitlement 或权限说明来掩盖问题 | 它们不会消除 App Data 授权，也不能修复身份漂移。 |

## 风险与边界

- 终端产品无法也不应阻止用户显式读取受保护目录；这类访问仍会遵循 macOS TCC。
- 本轮诊断曾用 `find` 扫描 `~/Library`，在 05:53:43 触发一次弹窗；已停止此类命令。
- 系统权限重置是外部状态写操作，未获明确授权前不执行。

## 参考指针

- `apps/desktop-macos/scripts/package-app.sh:13`
- `.github/workflows/ci.yml:51`
- `apps/runtime/src/daemon/daemon.ts:178`
- `.tmp/cmux/CHANGELOG.md:555`
