# 调研与结论：dev-stable-signing

- 任务 ID：`dev-stable-signing-2026-07-27_03-21-19`
- 创建时间：`2026-07-27_03-21-19`

## 需求事实

- 用户反馈 Acro dev 频繁出现 “Would like to access data from other apps”。
- 当前只有一套 UI/runtime；PID 1151 是热替换保留的 daemon，不是第二套 dev。

## 真实调用链

- `package-app.sh` 未设置 `ACRO_SIGN_IDENTITY` 时使用 ad-hoc 签名。
- ad-hoc designated requirement 绑定每次构建变化的 CDHash，TCC 无法复用既有授权。
- Acro 会读取 Codex 的 `~/.codex`，GhosttyKit 也会读取 Ghostty 配置；系统权限本身有真实业务原因。

## 调研结论

- 正式 `/Applications/Acro.app` 使用 Team `5UAHRS482C` 的 Developer ID，designated requirement 稳定。
- 当前任务 App 使用同一 Developer ID 热替换后，UI/runtime 正常，daemon 未重启。

## 技术决策

| 决策 | 证据 |
|---|---|
| 修正 dev 热替换入口，不改发布管线 | `package-app.sh` 已支持 `ACRO_SIGN_IDENTITY`，问题来自仓库指引漏传该变量 |
| 保留必要权限请求 | 移除 `~/.codex` 访问会破坏 Agent 会话管理，不能把产品能力当成弹窗补丁删除 |

## 风险与边界

- 稳定签名会让同一 Acro 身份复用权限；首次合法访问仍可能出现一次系统询问。
- 本轮只修复重复询问，不扩大或隐藏 Acro 的数据访问范围。

## 参考指针

- `apps/desktop-macos/scripts/package-app.sh:5-14,107-127`
- `apps/runtime/src/agent.ts:565-610,718-771`
- `apps/desktop-macos/Sources/Ghostty.swift:86`
