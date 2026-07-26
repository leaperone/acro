# 执行进度：desktop-tab-context-menu

- 任务 ID：`desktop-tab-context-menu-2026-07-27_07-20-39`
- 创建时间：`2026-07-27_07-20-39`
- 当前状态：`completed`

## 已完成

- 对照 Bonsplit 默认菜单、cmux handler 与 Acro Runtime/布局调用链。
- 确认需要宿主动作白名单，不能直接开启默认菜单。
- 确认首批可闭环动作和批量关闭根因。
- 增加 Bonsplit 白名单、Acro 菜单配置、批量确认和相邻窗格移动红色回归。
- 为 Bonsplit 增加默认兼容的动作 allowlist，并清理空菜单结构。
- Acro 接通七个支持动作；关闭类动作进入一次批量确认，移动、缩放和全宽复用 Bonsplit 原生路径。
- 批量终止复用单会话 `session.remove` / `session.kill` 语义，成功项关闭、失败项保留，最后只刷新一次。
- 增加简体中文菜单资源并保留英文、日文现有资源。

## 进行中

- 无。

## 修改文件

- vendored Bonsplit 菜单契约、配置、简体中文资源和测试。
- Acro 标签 controller、批量终止 model、确认对话框绑定和宿主测试。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 源码对照 | 默认菜单会暴露 Acro 无效动作 | 已确认 |
| Bonsplit 红测 | 缺少 `allowedActions` 菜单契约 | 按预期失败 |
| Desktop 红测 | 缺少允许动作配置与批量确认状态 | 按预期失败 |
| `swift test`（Bonsplit） | 204 项通过 | 已通过 |
| `swift test`（Desktop） | 81 项 XCTest + 30 项 Swift Testing 通过 | 已通过 |
| `swift test --filter TerminalPanesInteractionTests` | 23 项通过，含批量成功/失败混合路径 | 已通过 |
| `pnpm check` | protocol、CLI、Mobile、Runtime 全部通过 | 已通过 |
| `pnpm build` | CLI 与 Runtime 构建通过；只有既有 `import.meta` 警告 | 已通过 |
| release script tests | 2 项通过 | 已通过 |
| 本地化审计 | en/ja/zh-Hans plist 解析通过，九个可见 key 三语齐全，无新增裸英文 | 已通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 菜单 View 类型推断超时 | 1 | 提取菜单快照计算属性后通过。 |
| allowlist 参数无法传入默认成员初始化器 | 1 | 增加显式初始化器并保留默认 `nil`。 |
| 动态 destination ID 可能与动作 raw value 碰撞 | 1 | 过滤时同时检查 selector，并增加碰撞回归测试。 |
| 简体中文资源被 ignore | 1 | 显式加入 Git 索引；交付前复核 staged 文件。 |
