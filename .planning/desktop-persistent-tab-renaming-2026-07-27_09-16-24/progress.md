# 执行进度：desktop-persistent-tab-renaming

- 任务 ID：`desktop-persistent-tab-renaming-2026-07-27_09-16-24`
- 创建时间：`2026-07-27_09-16-24`
- 当前状态：`in_progress`

## 已完成

- 已核对 cmux rename/clear 语义、Acro 标题显示面、布局持久化链和旧快照兼容边界。
- 已确认最小根方案和验证范围。
- 已增加两条行为红测，分别证明布局 round-trip 丢失自定义标题、菜单未开放 rename / clear。

## 进行中

- 创建安全 worktree 并实现布局标题真源。

## 修改文件

- `.planning/desktop-persistent-tab-renaming-2026-07-27_09-16-24/*`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 只读调用链审计 | cmux 与 Acro 两条独立证据轨道结论一致 | 通过 |
| `PersistentTabTitleTests` 红测 | 当前实现重新编码后丢失 `customTitlesBySessionId` | 预期失败 |
| context action 红测 | 当前 allowlist 缺少 `.rename` / `.clearName` | 预期失败 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 0 | 无 |
