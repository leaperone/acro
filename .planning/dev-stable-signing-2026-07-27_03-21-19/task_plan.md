# 任务计划：dev-stable-signing

- 任务 ID：`dev-stable-signing-2026-07-27_03-21-19`
- 创建时间：`2026-07-27_03-21-19`

## 目标

让本机 Acro dev 热替换始终使用稳定代码签名，避免每次重新打包后 macOS 把它识别为新的 App Data 访问主体并重复询问权限。

## 范围

- 修正仓库内本机热替换命令。
- 增加签名身份验证步骤。

## 非目标

- 不删除 Acro 对 Codex、Ghostty 等开发工具数据的必要访问。
- 不重置 TCC，不修改正式发布签名流程。

## 关键约束

- 复用 `package-app.sh` 已有的 `ACRO_SIGN_IDENTITY`，不增加包装脚本或新签名机制。
- 保持 daemon 和现有终端会话不变。

## 修改路径

- `AGENTS.md`

## 验证方式

- 按新命令打包后检查 TeamIdentifier 和 designated requirement。
- 热替换 UI/runtime，确认 daemon PID 与 runtime health。

## 验收标准

- dev App 不再是 ad-hoc 签名。
- 相同 bundle id 与 Team ID 的重新构建保持稳定 designated requirement。
- 本机终端会话不丢失。

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
| 直接使用现有 `ACRO_SIGN_IDENTITY` | 打包脚本已经完整支持 Developer ID 签名，无需新增代码 |
| 不移除跨 App 数据访问 | Acro 管理 Codex 会话和兼容 Ghostty 配置需要这些访问；频繁询问来自签名身份漂移 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 签名打包最后创建 DMG 报 `Resource busy` | 1 | App 本体和签名已完成；不重复同一失败，记录为 DMG 环境问题 |
