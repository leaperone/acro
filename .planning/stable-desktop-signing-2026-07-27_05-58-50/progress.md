# 执行进度：stable-desktop-signing

- 任务 ID：`stable-desktop-signing-2026-07-27_05-58-50`
- 创建时间：`2026-07-27_05-58-50`
- 当前状态：`in_progress`

## 已完成

- 完成源码、进程、签名和 TCC 日志只读核对。
- 确认当前只有一个 dev 实例，helper/daemon 不是本次弹窗主体。
- 确认打包脚本的隐式 ad-hoc 默认值是可修复的身份漂移入口。
- 新增回归测试，当前在旧实现上按预期失败：脚本未输出签名策略错误并启动了 fake swift。

## 进行中

- 在打包入口要求显式 `ACRO_SIGN_IDENTITY`，并让 CI 显式选择 ad-hoc。

## 修改文件

- `apps/desktop-macos/scripts/test_package_app.py`：签名策略先红测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 运行时进程核对 | 单 UI/runtime/daemon/helper | 通过 |
| 当前 UI/helper 签名 | Developer ID + Team 5UAHRS482C | 通过 |
| TCC 日志 | 批量 prompt 来自 shell 子进程；旧 requirement 不匹配 | 通过 |
| `python3 -m unittest apps/desktop-macos/scripts/test_package_app.py` | 旧实现未在构建前拒绝缺失策略 | 预期失败 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 只读 `find ~/Library` 触发一次 App Data prompt | 1 | 停止受保护目录的无边界扫描；后续只读源码和统一日志。 |
