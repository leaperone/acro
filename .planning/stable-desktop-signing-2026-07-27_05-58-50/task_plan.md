# 任务计划：stable-desktop-signing

- 任务 ID：`stable-desktop-signing-2026-07-27_05-58-50`
- 创建时间：`2026-07-27_05-58-50`

## 目标

阻止本地桌面打包在未声明签名策略时静默生成 ad-hoc Acro.app，避免热替换后 macOS TCC 权限身份随 CDHash 漂移并反复弹窗。

## 范围

- `apps/desktop-macos/scripts/package-app.sh` 的签名入口守门。
- CI package smoke 显式声明 ad-hoc 策略。
- 增加脚本回归测试，证明缺少签名策略时会在构建前失败。

## 非目标

- 不拦截终端中用户或 Agent 对受保护目录的显式访问。
- 不修改 TCC 数据库、系统隐私设置、helper、daemon 或 Ghostty。
- 不发布 Beta；本任务只修开发打包身份。

## 关键约束

- 当前运行实例已是稳定 Developer ID；旧 TCC 记录需用户显式重授，代码不能代替系统授权。
- CI 可以使用 ad-hoc，但必须显式写出 `ACRO_SIGN_IDENTITY=-`。
- 保留现有正式发布签名和公证行为。

## 修改路径

- `apps/desktop-macos/scripts/package-app.sh`
- `.github/workflows/ci.yml`
- `apps/desktop-macos/scripts/test_package_app.py`

## 验证方式

- 先提交失败测试，证明当前脚本未设变量仍继续执行。
- 实现后运行脚本单测、全部 desktop release scripts 单测、`pnpm check`、`pnpm build`。
- CI package smoke 验证显式 ad-hoc 路径仍可完整打包。

## 验收标准

- 未声明 `ACRO_SIGN_IDENTITY` 时，脚本在任何构建和文件写入前失败并给出明确提示。
- 显式 `ACRO_SIGN_IDENTITY=-` 保持 CI ad-hoc 打包。
- Developer ID 发布路径不变。

## 未确认事项

没有则写“无”。

- 无。

## 执行状态

- [x] 完成只读探索并确认真实调用链
- [ ] 完成实现
- [ ] 完成验证
- [ ] 完成交付前收敛检查

## 决策

| 决策 | 理由 |
|---|---|
| 要求显式签名策略，不自动选择证书 | 脚本无法可靠替用户选择钥匙串证书；显式失败是最小且不会误签的根修。 |
| CI 显式使用 `-` | CI 只做包烟测，不持有发布证书；显式 ad-hoc 不会进入用户本机 TCC 生命周期。 |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| 无 | 1 | 无 |
