# 执行进度：bootstrap-grant-admin-scope

- 任务 ID：`bootstrap-grant-admin-scope-2026-08-09_23-06-08`
- 创建时间：`2026-08-09_23-06-08`
- 当前状态：`ready_for_delivery`

## 已完成

- 定位 CI 失败根因：`writeBootstrapOffer` 漏传 scope，引导设备缺 `admin`
- 枚举全部三个 grant 签发入口，确认只有 bootstrap 一处错误
- `writeBootstrapOffer` 显式授予 `ALL_RPC_SCOPES`
- 回归测试锁住三个入口的授权语义

## 修改文件

- `apps/runtime/src/share.ts`
- `apps/runtime/src/share.test.ts`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| `pnpm --filter @acro/runtime test` | 123 pass / 0 fail | 通过 |
| `pnpm -C apps/runtime e2e` | E2E PASS ✅ | 通过 |
| `pnpm check` | 全绿 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 修复初稿误写在主 checkout | 1 | 存 patch、还原主 checkout、建 worktree 后重新 apply |
| 本机 e2e 报 "daemon is outdated" | 1 | shell 继承已安装 Acro.app 的 `ACRO_DAEMON_ENTRY`（旧 daemon.cjs）；`env -u ACRO_DAEMON_ENTRY` 跑通，CI 无此变量 |
