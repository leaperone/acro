# 执行进度：desktop-tab-context-menu

- 任务 ID：`desktop-tab-context-menu-2026-07-27_07-20-39`
- 创建时间：`2026-07-27_07-20-39`
- 当前状态：`in_progress`

## 已完成

- 对照 Bonsplit 默认菜单、cmux handler 与 Acro Runtime/布局调用链。
- 确认需要宿主动作白名单，不能直接开启默认菜单。
- 确认首批可闭环动作和批量关闭根因。
- 增加 Bonsplit 白名单、Acro 菜单配置、批量确认和相邻窗格移动红色回归。

## 进行中

- 实现菜单白名单与 Acro 动作闭环。

## 修改文件

- 预计修改 vendored Bonsplit 菜单契约、Acro 标签 controller、批量终止 model 和对应测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码对照 | 默认菜单会暴露 Acro 无效动作 | 已确认 |
| Bonsplit 红测 | 缺少 `allowedActions` 菜单契约 | 按预期失败 |
| Desktop 红测 | 缺少允许动作配置与批量确认状态 | 按预期失败 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 无 | 1 | 无 |
