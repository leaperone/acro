# 执行进度：stable-helper-identity

- 任务 ID：`stable-helper-identity-2026-07-27_05-00-57`
- 创建时间：`2026-07-27_05-00-57`
- 当前状态：`in_progress`

## 已完成

- 核对当前 helper 进程、LaunchAgent、磁盘 inode、签名 requirement 和权限状态。
- 确认安装脚本缺少签名且 plist 指向仓库 `.build`。
- 确认 runtime 只通过固定 socket 连接，helper 可以独立迁移。
- 增加执行级回归测试，覆盖固定路径、稳定签名参数、版本替换和拒绝 ad-hoc。

## 进行中

- 使用真实 Developer ID 验证签名 requirement，再执行完整检查。

## 修改文件

- `.planning/stable-helper-identity-2026-07-27_05-00-57/*`
- 预计修改 `scripts/install-helper-launchagent.sh`、`scripts/install-launchagents.sh`、`scripts/test_install_helper_launchagent.py`。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 当前 helper 签名 | ad-hoc、无 Team ID、requirement 绑定 cdhash | 已确认缺陷 |
| 当前 plist | 指向仓库 `.build/release/acro-helper` | 已确认缺陷 |
| 当前权限 | accessibility=false，screenRecording=false | 已确认 |
| `python3 -m unittest apps.desktop-macos.scripts.test_install_helper_launchagent` | 缺少 `scripts/install-helper-launchagent.sh`，按预期失败 | 红色测试 |
| PR #129 首次 CI | `desktop-macos` 失败，`typescript` 通过 | 红色证据 |
| `bash -n scripts/install-helper-launchagent.sh scripts/install-launchagents.sh` | 通过 | 已通过 |
| `python3 -m unittest discover -s apps/desktop-macos/scripts -p 'test_*.py'` | 6 项通过 | 已通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 0 | 无 |
