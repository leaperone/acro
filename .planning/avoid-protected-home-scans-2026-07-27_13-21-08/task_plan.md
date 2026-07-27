# 任务计划：avoid-protected-home-scans

- 任务 ID：`avoid-protected-home-scans-2026-07-27_13-21-08`
- 创建时间：`2026-07-27_13-21-08`

## 目标

阻止 Acro 开发 Agent 无边界扫描用户目录，避免终端命令被 macOS 归因给 Acro 后连续触发 App Data、媒体资料库、Desktop、Documents、Downloads 和网络卷权限弹窗。

## 范围

- 在仓库开发指引中限定默认文件搜索范围和受保护目录访问条件。
- 明确 Acro 终端命令的 macOS 权限归因行为。

## 非目标

- 不修改 Acro 产品权限、Runtime、daemon 或 TCC 数据库。
- 不授予 Full Disk Access，不重启现有终端服务。

## 关键约束

- 保留用户明确授权后的精确跨目录检查能力。
- 不限制当前仓库、任务 worktree 和明确目标路径内的正常开发搜索。

## 修改路径

- `AGENTS.md`
- `.planning/avoid-protected-home-scans-2026-07-27_13-21-08/*`

## 验证方式

- 检查指引是否明确禁止 Home 根目录无边界遍历，并覆盖 macOS 受保护目录。
- 运行 planning 完整性检查和 `git diff --check`。

## 验收标准

- 后续 Agent 默认只在任务路径内使用 `rg` 搜索。
- 访问受保护目录前必须有用户明确范围和精确路径。
- 指引不建议用 Full Disk Access 绕过权限边界。

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
| 修 Agent 搜索边界，不改产品权限 | 系统日志证明真实请求方是 Acro 终端内的 `/usr/bin/find` |
| 保留精确授权访问 | Acro 本身需要执行开发任务，不能全面禁止跨目录读取 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| TCC 数据库不可读 | 1 | 改用统一日志中的 service、responsible path 和 binary path 形成证据链 |
