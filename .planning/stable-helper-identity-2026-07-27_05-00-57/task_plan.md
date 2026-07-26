# 任务计划：stable-helper-identity

- 任务 ID：`stable-helper-identity-2026-07-27_05-00-57`
- 创建时间：`2026-07-27_05-00-57`

## 目标

让 macOS Computer Use helper 使用固定安装路径、固定 bundle identifier 和 Acro Developer ID 签名，使辅助功能与屏幕录制授权不再因仓库重编译、worktree 或构建产物路径变化而失效。

## 范围

- 新增 helper 专用安装脚本，负责构建/签名/验证/原子安装和 LaunchAgent plist。
- 让现有 `install-launchagents.sh` 复用该共享入口。
- 增加执行级安装测试，验证固定路径、签名参数和拒绝 ad-hoc。

## 非目标

- 不把 helper 打进 Acro.app；这属于分发架构变化。
- 不修改或清空 TCC 数据库。
- 不自动重启 runtime/daemon，不影响终端会话。

## 关键约束

- 没有 Developer ID 时必须失败，禁止回退 ad-hoc。
- identifier 固定为 `one.leaper.acro.helper`。
- 安装路径固定为 `~/.acro/bin/acro-helper`，LaunchAgent 不再指向仓库 `.build`。
- 替换必须原子完成；签名或验证失败不得覆盖现有 helper。

## 修改路径

- `scripts/install-helper-launchagent.sh`
- `scripts/install-launchagents.sh`
- `scripts/test_install_helper_launchagent.py`

## 验证方式

- 先提交会失败的安装行为测试，再实现脚本。
- Python 测试使用临时 HOME、假 codesign 和预构建 helper，验证生成产物与失败边界。
- 本机用真实 Developer ID 安装并核对 designated requirement、Team ID、固定路径与 LaunchAgent 进程。
- `pnpm check`、`pnpm build`、CI。

## 验收标准

- 两个内容不同的 helper 版本通过同一脚本安装时，路径、identifier 和 Developer ID requirement 保持稳定。
- `ACRO_SIGN_IDENTITY=-` 或无可用 Developer ID 时安装失败。
- 当前 helper 迁移到固定路径并重启后，runtime 的 `computer.permissions` 仍可连接。

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
| helper 独立安装入口 | 避免为更新 Computer Use helper 重写或重启 runtime LaunchAgent |
| 固定路径 + Developer ID + identifier | 三者共同构成可跨版本复用的稳定 TCC 身份 |
| 不允许 ad-hoc fallback | ad-hoc requirement 绑定 cdhash，正是权限反复失效的根因 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 0 | 无 |
| 临时 HOME 下真实签名找不到证书 | 1 | 临时 HOME 隐藏登录钥匙串；改为在 `/tmp` 手工 staging、保留真实 HOME 验证同一签名命令 |
