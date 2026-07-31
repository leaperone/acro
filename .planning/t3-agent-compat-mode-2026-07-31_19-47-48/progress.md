# 执行进度：t3-agent-compat-mode

- 任务 ID：`t3-agent-compat-mode-2026-07-31_19-47-48`
- 创建时间：`2026-07-31_19-47-48`
- 当前状态：`delivery_ready`

## 已完成

- 核对 Acro 蓝图、Runtime、terminal daemon、Desktop 子进程和打包签名链。
- 核对 T3 Server CLI、desktop bootstrap、browser session、Provider、Web UI 和许可证边界。
- 比较完整源码 fork、原生 SwiftUI 重写和官方 package sidecar 三种路径。
- 选择固定官方 `t3` 包 + loopback sidecar + WKWebView 的最小兼容方案。
- 明确 Acro/T3 状态、PTY、Git 与认证隔离边界。
- 明确首版 local-only，禁止把 Desktop 本机 T3 误投影为远端 Acro Server 能力。
- 明确健康 T3 sidecar 脱离窗口生命周期，并通过身份验证重新附着。
- 完成实施路径、验证方法、验收标准、风险和非目标。

## 进行中

- 无。实现与本地验证已完成，等待 Git/PR 收敛。

## 本轮实现增量

- 已验证 npm 发布包、Node engine、静态 Web UI、browser-session cookie 与 runtime-state 契约。
- 已新增 `apps/t3-compat` 并在当前 Node 下实际启动官方发布包。
- 已否决 `--no-optional` production deploy：缺少 `@yuuang/ffi-rs-darwin-arm64` 时 T3 在启动阶段失败。
- 已实现原生 sidecar manager、shell 环境恢复、runtime-state 重附着、HttpOnly cookie bootstrap、WKWebView 同源策略和工作台模式切换。
- 已补齐长期重附着：先验证 WKWebView 持久 browser-session cookie，再按需使用 24 小时 desktop bootstrap grant。
- 已将完整 T3 production closure、第三方声明、Node engine 闸和嵌套 Mach-O 签名纳入 App 打包。
- 已完成真实 ad-hoc App 验收：T3 Web UI 加载、返回工作台、App 退出后 sidecar 保活、同状态目录重开后附着同一 PID/port；Acro daemon PID 全程保持 `9671`。
- 测试 App 与测试 T3 sidecar 已精确终止；现有安装版 Acro 与 daemon 未改动。

## 修改文件

- Planning 与蓝图：`.planning/blueprint.md`、`.planning/t3-agent-compat-mode-2026-07-31_19-47-48/`
- Desktop：T3 sidecar manager、WKWebView、模式入口、三语言文案与 Swift 测试
- 打包与依赖：`apps/t3-compat/`、`package-app.sh`、pnpm workspace/lockfile、第三方声明与打包测试

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Planning 三文件存在 | 目标目录内三文件齐全 | 通过 |
| 范围与非目标 | 隔离 sidecar、Desktop 首版、无 PTY 桥接边界明确 | 通过 |
| 实施路径 | 依赖、打包、sidecar、认证、WebView、模式入口、测试均有路径 | 通过 |
| 安全与许可证 | loopback、bootstrap、目录权限、MIT/商标边界明确 | 通过 |
| 验收标准 | 包含离线、签名、真实 Provider、模式切换和 daemon 连续性 | 通过 |
| `check-complete.sh` | planning delivery-ready | 通过 |
| `git diff origin/main...HEAD --check` | 无空白错误 | 通过 |
| `git merge-tree --write-tree HEAD origin/main` | 成功生成合并树，无冲突 | 通过 |
| 内容审查 | 修正 local-only 与 sidecar 窗口生命周期边界后，无 critical/high | 通过 |
| PR 身份 | PR #150、base `main`、head 分支与 SHA 一致、mergeable | 通过 |
| GitHub CI | PR #150 的 `typescript` 与 `desktop-macos` checks 在实现 HEAD `451837f` 上成功 | 通过 |
| 代码实现 | 本机 Agent 模式、sidecar、WebView、打包与声明均已完成 | 通过 |
| T3 针对性 Swift 测试 | `T3CompatTests` 5 项通过 | 通过 |
| 打包契约测试 | `test_package_app.py` 4 项通过 | 通过 |
| ad-hoc App 打包 | 完整 production closure、深度 codesign、zip/dmg 生成成功 | 通过 |
| 嵌套 Mach-O 签名枚举 | 对实际 closure 全量识别并 ad-hoc 逐个重签，含 resource monitor、Claude binary 与 `.dylib`；整包 strict verify 通过 | 通过 |
| 包内离线 sidecar | `serverVersion=0.0.31`、`browser-session-cookie`、HttpOnly | 通过 |
| 包内 Project/Git 基线 | 临时 Git 仓库经 `t3 project add --base-dir` 持久化成功；重复添加以 `ProjectAlreadyExistsError` fail closed | 通过 |
| 真实 WKWebView | Computer Use 看到 `T3 Code (Alpha)`、Projects、Add project 等真实上游 UI | 通过 |
| 生命周期边界 | App 退出后 T3 PID `78068` 继续运行；重开附着同一 `127.0.0.1:58930` | 通过 |
| Acro daemon 连续性 | 模式切换、App 退出/重开期间 daemon PID 均为 `9671` | 通过 |
| 烟测清理 | ad-hoc App 与测试 sidecar 已终止，安装版 Acro/daemon 保留 | 通过 |

## Git 与交付状态

- 分支：`plan/t3-agent-compat-mode`
- 提交：实现提交 `451837fa1c4c600fde670f68780d5c654cea7fc7` 已 push；最终 planning 元数据同步后重新核对 HEAD/PR 身份。
- PR：`https://github.com/leaperone/acro/pull/150`
- 合并：尚未执行；交付前运行 preflight 并按其结论处理。
- 发布/部署：未执行；本任务不发布 Desktop。

## 发布前仍需人工验收

- 使用实际已配置 Provider 完成一次新 Thread、流式回复、工具审批和用户输入；本轮未发送付费模型请求。
- 使用 Developer ID 正式签名后执行公证、Gatekeeper 与真实升级包验证；本轮完成的是 ad-hoc 打包和全 closure 签名枚举验证。

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| `ERR_PNPM_IGNORED_BUILDS: msgpackr-extract@3.0.4` | 1 | 明确禁止可选 native 加速脚本，使用纯 JS fallback，不扩大签名面 |
| `--no-optional` 部署产物启动时报 `Cannot find module '@yuuang/ffi-rs-darwin-arm64'` | 1 | 保留完整 production closure；不再整批删除 optional dependencies |
| ad-hoc App 深度签名校验报 `invalid destination for symbolic link in bundle` | 1 | 删除 legacy deploy 生成的 workspace 自引用 symlink，并把整包 `codesign --verify --deep --strict` 加入打包闸 |
| 第二次本地打包触发 `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` | 1 | legacy deploy 后立即用 `CI=true pnpm install` 恢复共享 workspace 模块状态；不改变全仓 inject 语义 |
| 正式签名枚举漏掉无执行位 resource monitor 与 `.dylib` | 1 | 遍历 runtime/T3 全 closure，以 Mach-O 文件类型为真源逐个签名 |
