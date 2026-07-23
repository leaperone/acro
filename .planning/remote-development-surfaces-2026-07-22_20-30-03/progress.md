# 执行进度：remote-development-surfaces

- 任务 ID：remote-development-surfaces-2026-07-22_20-30-03
- 创建时间：2026-07-22_20-30-03
- 当前状态：planning_complete
- 本轮边界：只完成完整规划，不实现功能
- 补充轮次：2026-07-23 根据 Acro 与最新 Orca 模块差异补齐 planning
- 当前分支：docs/complete-remote-development-planning
- 当前 worktree：/Users/harry/project/acro/.worktrees/docs-complete-remote-development-planning

## 2026-07-23 补齐内容

- 用户要求把 Acro 与 Orca 的功能模块差异补进现有 planning，不新建重复任务目录。
- 用户要求 `.tmp/orca` 拉取最新 main；参考仓库已更新并确认 HEAD/origin/main 为 `88b7e69b`，工作树干净。
- 以 28 个用户可感知模块重新分类：10 个已覆盖、9 个应补齐、1 个规格冲突、6 个明确不复制、2 个可选扩展。
- 把以下核心缺口纳入 task_plan：
  - 完整 CLI 控制面。
  - Browser 可见 Surface 与语义自动化。
  - iOS Simulator 实时画面、输入和完整生命周期。
  - Computer Use 稳定 provider 与客户端入口。
  - Mobile Server → Workspace → Surface 工作台。
  - 通用 Agent 状态和会话定位。
  - Runtime 持久通知、按设备未读和最小化后台推送。
  - 用户可操作的诊断页、协议兼容闸门和脱敏报告。
- 单列 Workspace / Project 规格冲突，并新增阶段 -1 用户决策门；planning 不暗选任一架构契约。
- 明确 Agent 状态由显式 hook 适配器和受限 OSC 消息产生，不解析普通 PTY 文本，也不把供应商逻辑放进 Runtime 核心。
- 明确 OSC 只能上报不可操作状态；needs_user 只通知并定位会话，客户端不生成审批按钮或终端输入。
- 明确相同 Agent 状态按 Session 去重，高频切换合并为最新事实，needs_user 通知和 Push 保持有界。
- 明确通知真实内容只保存在 Runtime，经 E2EE 拉取；推送服务只接收随机 pushRouteId 和 opaque notificationId。
- 明确客户端按每个配对 Server 保存 pushRouteId 映射，覆盖多服务器相同 notificationId、未知 route 和 route 轮换。
- 区分 Expo push/access token 与 Acro 配对认证 token；前者是第三方交付所需凭证，后者和 E2EE 密钥绝不进入推送服务。
- 本轮没有修改产品代码、依赖、蓝图、发布配置或本机 dev 实例。

## 已完成

- 检查主 checkout、当前分支、dirty 文件和已有 worktree。
- 保留主 checkout 中用户对 .agents/skills/release/SKILL.md 的修改，未 stash、未覆盖。
- 创建隔离规划 worktree：
  - 分支：plan/remote-development-surfaces
  - 路径：/Users/harry/project/acro/.worktrees/plan-remote-development-surfaces
- 校验 leaperone 项目基线：.planning、.worktrees ignore、AGENTS.md 和 CLAUDE.md 均符合要求。
- 阅读 Acro 蓝图、协议、Runtime、Desktop、Mobile 和 helper 的真实调用链。
- 审查阶段补充读取现有 apps/cli，确认复用配对、连接、参数和背压实现。
- 第二轮审查删除未证实需要的画面 keyframe 标志和新本机 socket，并补齐 Browser title 与 URL 同步。
- 第三轮审查分离布局移除与领域终止，避免关闭 Simulator 或 Computer Use 时误执行破坏性动作。
- 阅读 apps/mobile/AGENTS.md；确认实现移动端前必须查 Expo 57 精确文档。
- 只读调研 Orca Browser、Emulator、Computer Use 与 cmux Browser 参考实现。
- 核对 agent-browser 与 serve-sim 的 npm 许可证和固定版本候选。
- 形成协议、兼容、Browser、Simulator、Computer Use、客户端、CLI、skills、打包与端到端验收的完整计划。
- 明确本轮不创建产品代码、依赖、空应用或发布产物。

## 本轮未执行

- 产品实现未开始。
- 未修改 .planning/blueprint.md，因为本轮没有改变已生效架构。
- 未打包或热替换本机 dev app。
- 未发布 desktop 版本。

## 修改文件

- .planning/remote-development-surfaces-2026-07-22_20-30-03/task_plan.md
  - 补齐阶段 -1、移动工作台、完整 CLI、Agent 状态、通知未读、诊断兼容、修改路径和验收标准。
- .planning/remote-development-surfaces-2026-07-22_20-30-03/findings.md
  - 补齐 Acro/Orca commit 基线、28 模块总账、53/16 RPC 可达性、Project 冲突、反事实修正和根因设计。
- .planning/remote-development-surfaces-2026-07-22_20-30-03/progress.md
  - 记录本次补齐范围、分支、worktree、实施入口和检查结果。

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Runtime 基线测试 | 101 项通过 | 通过 |
| Protocol 基线测试 | 11 项通过 | 通过 |
| Mobile 基线测试 | 5 项通过 | 通过 |
| Runtime typecheck | 无错误 | 通过 |
| Protocol typecheck | 无错误 | 通过 |
| Swift helper build | 构建成功 | 通过 |
| 三文件无待填写标记 | 已写满 | 通过 |
| 三文件无未完成复选框 | 未使用未完成复选框 | 通过 |
| planning 完整性脚本 | Planning complete | 通过 |
| Git diff 边界 | 仅三份 planning 文件 | 通过 |
| 2026-07-23 planning 补齐复检 | Planning complete；无未完成复选框或待填写占位 | 通过 |
| 2026-07-23 diff 检查 | git diff --check 无错误；仍只改三份 planning 文件 | 通过 |
| 2026-07-23 pnpm check | Protocol、Runtime、Mobile、CLI 全部通过 | 通过 |
| 2026-07-23 pnpm build | CLI、Runtime 构建通过；只有既有 import.meta/CJS 警告 | 通过 |
| 2026-07-23 merge probe | 与 origin/main 合并树生成成功，无冲突 | 通过 |
| PR | #110：docs: complete remote development planning | 已创建 |
| 2026-07-23 preflight 文档审查 | 首轮发现 OSC 可执行输入 High 与多服务器 Push 路由 Medium；二轮补充状态 Push 风暴与 token 边界 Medium | 三轮复检通过，无 Critical/High/Medium |

基线测试来自只读调研阶段，只证明现有代码状态。计划功能尚未实现，因此没有功能完成声明。

## 后续实施入口

后续执行者从 task_plan.md 的阶段 -1 开始：

1. 先由用户裁决 Workspace / Project 唯一契约，并同步文档与数据模型。
2. 再冻结协议、旧布局和旧帧兼容夹具。
3. 实现 server.info、稳定错误和共享流控。
4. 之后按 Browser、Simulator、Computer Use、客户端、CLI 和发布顺序推进。
5. 完成阶段 7 后，继续执行 7A Agent 状态、7B 通知未读和 7C 诊断兼容。
6. 每个阶段只在自己的入口条件满足后开始，并完成对应验证。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 规划 worktree 中没有 .tmp/orca 与 .tmp/cmux | 1 | 从主 checkout 只读参考；未修改参考目录 |
| development-guard 因模板未填写阻止继续搜索 | 1 | 先写满三文件，再运行完整性与 diff 检查 |
| 初稿误把 apps/cli 当作待创建应用 | 1 | preflight 审查发现后改为扩展现有 CLI，并补齐真实调用链 |
| 本机 git merge-tree 不接受文档中的三位置参数写法 | 1 | 使用本机支持的 --merge-base 参数完成同等无冲突探测 |
| 旧 plan/remote-development-surfaces worktree 已与 main 双向分叉，远端分支也已删除 | 1 | 保留旧 worktree，不在其上续写；从当前 origin/main 创建 docs/complete-remote-development-planning |
