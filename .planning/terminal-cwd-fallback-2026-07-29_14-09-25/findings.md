# 调研与结论：terminal-cwd-fallback

- 任务 ID：`terminal-cwd-fallback-2026-07-29_14-09-25`
- 创建时间：`2026-07-29_14-09-25`

## 需求事实

- 用户在已重启的最新 Acro dev App 中，`⌘T` 与 `⌘D` 仍显示“source terminal working directory is unavailable”。

## 真实调用链

- `⌘T` / `⌘D` -> `TerminalPaneController.createTerminal` -> `WorkbenchModel.createTerminalForPaneController` -> RPC `session.create`，请求携带 `inheritCwdFrom`。
- Runtime 以 `session.cwd` 取来源终端实时 cwd；空值时在 `apps/runtime/src/index.ts` 抛出该错误。

## 调研结论

- 这不是 cmux 全局 `workspaceInheritWorkingDirectory` 的作用域；Acro runtime 是实际报错源。
- `packages/protocol/src/rpc.ts` 已说明：显式 cwd、来源实时 cwd 都没有时使用家目录。Runtime 的最终 `cwd ?? os.homedir()` 也已实现该回退，只是前置抛错阻断了它。
- E2E 的终端输出回显早于 daemon `lsof` cwd 查询稳定；可读 cwd 的两个断言先轮询 `session.cwd`，避免把时序误判为回退。

## 技术决策

| 决策 | 证据 |
|---|---|
| 删除空 cwd 的拒绝，沿用现有 `os.homedir()` 回退 | 最小共享修复，同时覆盖 `⌘T`、`⌘D` 和其他继承调用方。 |

## 风险与边界

- 不把来源 cwd 错误静默为任意旧路径；只使用已定义的家目录回退。

## 参考指针

- `apps/runtime/src/index.ts:563-606`
- `apps/runtime/scripts/e2e.ts:797-825`
- `apps/desktop-macos/Sources/WorkbenchModel.swift:1050-1063`
