# 任务计划：terminal-cwd-fallback

- 任务 ID：`terminal-cwd-fallback-2026-07-29_14-09-25`
- 创建时间：`2026-07-29_14-09-25`

## 目标

让 Acro 的 `⌘T` 与 `⌘D` 在来源终端暂时不能报告工作目录时仍创建终端，并回退到家目录。

## 范围

- `apps/runtime/src/index.ts` 的 `session.create` cwd 解析。
- 现有 runtime E2E 覆盖继承失败与成功两条路径。

## 非目标

- 不修改 cmux 全局配置、快捷键映射、终端 daemon 协议或工作区布局。

## 关键约束

- 显式 cwd 与可读取来源 cwd 的既有行为不变。
- 无法读取来源 cwd 时遵循协议注释，回退 `os.homedir()`。
- 仅修改本任务文件，保留主 checkout 既有未提交改动。

## 修改路径

- `apps/runtime/src/index.ts`
- `apps/runtime/scripts/e2e.ts`

## 验证方式

- 运行 runtime E2E 与受影响的 release 构建检查。

## 验收标准

- `⌘T` / `⌘D` 路径不会再因 cwd 不可读报错。
- 可读 cwd 仍原样继承；不可读时新会话 cwd 为家目录。

## 未确认事项

没有则写“无”。

无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 不可读继承 cwd 回退家目录 | `session.create` 最终已有 `cwd ?? os.homedir()`，删除中途拒绝即可覆盖所有调用方。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| runtime E2E 初次即时读取 cwd 失败 | 1 | 为可读 cwd 断言增加最多 5 秒的真实 cwd 报告轮询；E2E 已通过。 |
