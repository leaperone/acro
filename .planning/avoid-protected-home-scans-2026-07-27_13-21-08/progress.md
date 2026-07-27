# 执行进度：avoid-protected-home-scans

- 任务 ID：`avoid-protected-home-scans-2026-07-27_13-21-08`
- 创建时间：`2026-07-27_13-21-08`
- 当前状态：`complete`

## 已完成

- 核对 UI、runtime、daemon 进程来源和两份 App 的签名身份。
- 从 TCC 日志确认真实 prompting 服务、负责 App 路径和访问 binary。
- 增加 Acro 开发 Agent 的本机搜索与权限边界。

## 进行中

- 无。

## 修改文件

- `AGENTS.md`
- `.planning/avoid-protected-home-scans-2026-07-27_13-21-08/*`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| TCC 真实提示源 | `/usr/bin/find` 触发六类受保护数据访问 | 通过 |
| 进程拓扑 | 一个 Beta.25 UI/runtime 加一个旧 dev daemon | 通过 |
| `git diff --check` | 无空白或补丁格式问题 | 通过 |
| planning 完整性 | 三文件无占位符、无未完成事项 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 用户 TCC.db 无读取权限 | 1 | 使用 unified log 核对真实服务与 attribution |
