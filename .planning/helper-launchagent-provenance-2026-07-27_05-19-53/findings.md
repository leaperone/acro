# 调研与结论：helper-launchagent-provenance

- 任务 ID：`helper-launchagent-provenance-2026-07-27_05-19-53`
- 创建时间：`2026-07-27_05-19-53`

## 需求事实

- PR #129 合并后，真实 Developer ID helper 安装成功，但第一次 `launchctl bootstrap` 返回 `Bootstrap failed: 5: Input/output error`。
- plist 语法、文件权限、固定路径和代码签名均验证正确。

## 真实调用链

- staged helper 与 staged plist 都带 `com.apple.provenance`。
- 对已安装的 binary 与 plist 执行 `xattr -d com.apple.provenance` 后，同一次 bootstrap 立即成功。
- helper 新 PID 为 50844，runtime PID 9206、daemon PID 1151 均未变化。

## 调研结论

- launchd 阻断来自本轮生成文件的 provenance，不是签名 requirement、plist 或进程冲突。
- 清理动作必须发生在 staged 文件上、原子替换前，避免安装一个 launchd 无法加载的版本。

## 技术决策

| 决策 | 证据 |
|---|---|
| 对 staged binary 与 plist 分别删除 provenance | 现场相同文件删除后 bootstrap 成功 |

## 风险与边界

- `xattr -d` 在属性不存在时会失败，脚本需要忽略“属性不存在”，但不能掩盖其它安装失败。

## 参考指针

- `scripts/install-helper-launchagent.sh`
- PR #129 merge commit `36ab06880f3b201939f5dd6b44791889defcc263`
