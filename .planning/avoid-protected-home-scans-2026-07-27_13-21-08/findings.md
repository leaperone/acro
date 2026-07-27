# 调研与结论：avoid-protected-home-scans

- 任务 ID：`avoid-protected-home-scans-2026-07-27_13-21-08`
- 创建时间：`2026-07-27_13-21-08`

## 需求事实

- 用户反馈 Acro dev 频繁出现 “Would like to access data from other apps”。
- 当前运行的是 `/Applications/Acro.app` Beta.25 UI/runtime，加一个由仓库 `dist/Acro.app` 启动并保留 PTY 的旧 daemon；不是两个完整 dev UI。

## 真实调用链

- macOS TCC 日志把权限主体记录为 `one.leaper.acro.desktop`，responsible path 是仓库 `dist/Acro.app`。
- 真正访问数据的 binary 是 Acro 终端内启动的 `/usr/bin/find`。
- 2026-07-27 10:42 至 10:51 的真实 prompting 依次覆盖 SystemPolicyAppData、MediaLibrary、NetworkVolumes、DesktopFolder、DocumentsFolder 和 DownloadsFolder。

## 调研结论

- 连续弹窗来自一次无边界文件遍历依次碰到多个 macOS 受保护目录，不是 Acro UI 主动读取其它 App 数据。
- Developer ID 稳定签名可以避免同一权限随构建身份漂移，但不能阻止无边界 `find` 首次触发不同权限类别。
- 根因修复是约束 Agent 的搜索范围；Full Disk Access 只会隐藏问题并扩大权限。

## 技术决策

| 决策 | 证据 |
|---|---|
| 禁止 Home 根目录递归遍历 | 真实 prompting 的 accessing binary 均为 `/usr/bin/find` |
| 明确受保护目录清单 | TCC 日志逐项记录 App Data、媒体、网络卷和用户文件夹服务 |

## 风险与边界

- 已经产生的系统授权记录不做清理；规则只防止后续误触发。
- 用户明确要求检查某个受保护路径时仍可执行精确访问。

## 参考指针

- macOS unified log：`tccd` 的 `AUTHREQ_PROMPTING` 与 `kTCCServiceSystemPolicyAppData` 记录。
- `AGENTS.md` 的“本机文件搜索与权限”。
