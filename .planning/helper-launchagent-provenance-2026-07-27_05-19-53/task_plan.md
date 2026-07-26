# 任务计划：helper-launchagent-provenance

- 任务 ID：`helper-launchagent-provenance-2026-07-27_05-19-53`
- 创建时间：`2026-07-27_05-19-53`

## 目标

移除安装过程中 helper 与 LaunchAgent plist 的 macOS provenance 扩展属性，确保签名 helper 可以被 `launchctl bootstrap` 正常加载。

## 范围

- 在原子安装前清除本轮生成文件的 `com.apple.provenance`。
- 增加执行级回归测试，锁定清理命令覆盖 binary 与 plist。

## 非目标

- 不改变签名身份、安装路径或 LaunchAgent 生命周期策略。
- 不修改 TCC 数据库，不重启 runtime/daemon。

## 关键约束

- 只处理本轮生成的 staged 文件。
- 其它 xattr 不扩展处理；已确认阻断 launchd 的是 provenance。

## 修改路径

- `scripts/install-helper-launchagent.sh`
- `apps/desktop-macos/scripts/test_install_helper_launchagent.py`

## 验证方式

- 先提交失败测试并取得 CI 红色证据。
- 运行脚本测试、`pnpm check`、`pnpm build` 与 CI。
- 本机重新安装并重载 helper，确认 bootstrap、签名、权限 RPC 和 daemon 保持正常。

## 验收标准

- [ ] 新生成的 binary 与 plist 在安装前执行 provenance 清理。
- [ ] `launchctl bootstrap` 可加载固定路径的签名 helper。
- [ ] runtime 与 daemon 不重启，Computer Use 权限 RPC 可连接。

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
| 只删除 `com.apple.provenance` | 现场删除该属性后，同一 binary/plist 立即 bootstrap 成功；无需清空其它 xattr |

## 错误与处理

| 错误 | 尝试 | 处理结果 |
|---|---:|---|
| `launchctl bootstrap` 返回 I/O error | 1 | 只读确认 plist、签名、权限均正常；删除 provenance 后同一服务加载成功 |
