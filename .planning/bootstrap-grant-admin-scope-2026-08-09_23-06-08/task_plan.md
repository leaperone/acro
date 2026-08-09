# 任务计划：bootstrap-grant-admin-scope

- 任务 ID：`bootstrap-grant-admin-scope-2026-08-09_23-06-08`
- 创建时间：`2026-08-09_23-06-08`

## 目标

修复 #151 引入的回归：首次启动生成的 bootstrap 配对码只拿到默认 scope（`read` + `control`），
缺 `admin`，导致这台 Runtime 的**第一台设备无法再配对第二台**，Runtime 锁死在单设备状态。
CI 的 `runtime e2e` 在 main 上因此变红。

## 范围

- `writeBootstrapOffer` 显式授予全 scope。
- 回归测试：bootstrap grant 与 local grant 都必须持全 scope，普通 `device.share` 仍是最小授权。

## 非目标

- 不改 scope 档位划分、`METHOD_SCOPES` 或默认分享策略（`DEFAULT_GRANT_SCOPES` 保持 `read` + `control`）。
- 不改 e2e 脚本去迁就实现——e2e 暴露的是真实产品缺陷。

## 关键约束

- bootstrap 与 local 是「这台 Runtime 的管理入口」，必须能配对后续设备。
- 普通远程分享仍须保持最小授权，不得被本次修复放宽。

## 修改路径

- `apps/runtime/src/share.ts`：`writeBootstrapOffer` 传 `ALL_RPC_SCOPES`
- `apps/runtime/src/share.test.ts`：回归测试

## 验证方式

- `pnpm --filter @acro/runtime test`
- `pnpm -C apps/runtime e2e`（正是它抓到的缺陷）
- `pnpm check`

## 验收标准

- [x] bootstrap grant 持 `read` / `control` / `computer` / `admin`
- [x] local grant 持全 scope（既有行为不回归）
- [x] 普通 `device.share` 仍只给 `read` + `control`
- [x] `runtime e2e` 通过
- [x] main 的 CI 恢复绿色

## 未确认事项

- 无

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [x] 完成实现
- [x] 完成验证
- [x] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| bootstrap 授予全 scope 而非仅补 admin | 引导设备是首台管理设备，与 local grant 同性质；只补 admin 会留下「能配对但不能用 Computer Use」的怪异中间态 |
| 不放宽 `DEFAULT_GRANT_SCOPES` | 缺陷在引导入口漏传 scope，不在默认策略本身；放宽会让所有远程分享失去最小授权 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| #151 的 Exploring 只覆盖 `createShareOffer`，漏掉 `writeBootstrapOffer` / `ensureLocalOffer` 两个 grant 创建入口 | 1 | 本次补齐并加回归测试锁住三个入口的授权语义 |
| 本机 e2e 报 "daemon is outdated" | 1 | 非代码缺陷：shell 继承自已安装 Acro.app 的 `ACRO_DAEMON_ENTRY`，指向旧 `daemon.cjs`。用 `env -u ACRO_DAEMON_ENTRY` 跑通；CI 无此变量 |
