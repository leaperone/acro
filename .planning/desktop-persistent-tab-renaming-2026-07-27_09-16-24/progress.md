# 执行进度：desktop-persistent-tab-renaming

- 任务 ID：`desktop-persistent-tab-renaming-2026-07-27_09-16-24`
- 创建时间：`2026-07-27_09-16-24`
- 当前状态：`ready_for_delivery`

## 已完成

- 已核对 cmux rename/clear 语义、Acro 标题显示面、布局持久化链和旧快照兼容边界。
- 已确认最小根方案和验证范围。
- 已增加两条行为红测，分别证明布局 round-trip 丢失自定义标题、菜单未开放 rename / clear。
- 已实现 scoped layout 自定义标题、统一标题优先级、rename / clear 菜单和 metadata-only 更新。
- 已增加中英日对话框文案、简体中文 Bonsplit 菜单文案和打包资源校验。
- 已完成针对性、Desktop、Bonsplit、TypeScript、构建和真实 `.app` 包验证。

## 进行中

- Git / PR / preflight 和 Beta 发布。

## 修改文件

- `.planning/desktop-persistent-tab-renaming-2026-07-27_09-16-24/*`
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
- `apps/desktop-macos/Sources/WorkbenchModel.swift`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Tests/PersistentTabTitleTests.swift`
- `apps/desktop-macos/Tests/TerminalPanesInteractionTests.swift`
- `apps/desktop-macos/Localization/*/Localizable.strings`
- `apps/desktop-macos/Vendor/bonsplit/.../zh-Hans.lproj/Localizable.strings`
- `apps/desktop-macos/scripts/package-app.sh`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| 只读调用链审计 | cmux 与 Acro 两条独立证据轨道结论一致 | 通过 |
| `PersistentTabTitleTests` 红测 | 当前实现重新编码后丢失 `customTitlesBySessionId` | 预期失败 |
| context action 红测 | 当前 allowlist 缺少 `.rename` / `.clearName` | 预期失败 |
| `PersistentTabTitleTests` | 5 项通过 | 通过 |
| Desktop 全量 | 81 XCTest + 39 Swift Testing 通过 | 通过 |
| Bonsplit | 204 项通过 | 通过 |
| `pnpm check` | TypeScript 检查与 15 项 Node 测试通过 | 通过 |
| `pnpm build` | CLI/runtime 构建通过；仅现有 `import.meta` 警告 | 通过 |
| release scripts | 7 项 Python unittest 通过 | 通过 |
| localization audit | 三语言 key 一致，6 个 `.strings` 文件均可解析 | 通过 |
| package smoke | `.app` 含三种语言资源、DevelopmentRegion=en、签名校验通过 | 通过 |
| macOS TCC 日志 | 确认 `SystemPolicyAppData` 弹窗由相同 Bundle ID 的 Developer ID / ad-hoc 身份冲突触发 | 通过 |
| 首次 Bonsplit bundle 产物尝试 | App 根目录资源被 codesign 拒绝；已改为合法的 `Contents/Resources` 加载路径 | 已纠正 |
| `test_package_app.py` | 3 项通过，覆盖显式签名、ad-hoc 独立身份和 Bonsplit 资源嵌入 | 通过 |
| Desktop 全量复验 | 81 XCTest + 39 Swift Testing 通过 | 通过 |
| Bonsplit 全量复验 | 204 项通过 | 通过 |
| ad-hoc 真实产物 | ID=`one.leaper.acro.desktop.adhoc`、显示名=`Acro Ad Hoc`、deep/strict codesign 通过 | 通过 |
| Bonsplit 产物资源 | `Contents/Resources/Bonsplit_Bonsplit.bundle` 三语 strings 可解析 | 通过 |
| `pnpm check` 复验 | TypeScript 与 15 项 Node 测试通过 | 通过 |
| `git diff --check` | 无空白错误 | 通过 |
| 最终 diff 审查第 1 轮 | 发现正式 Bundle ID 未拒绝错误证书身份 | 已修复 |
| 正式签名身份断言 | Beta.21 产物满足 Developer ID Application、Team `5UAHRS482C` 和稳定 requirement | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| Swift Testing mutating 宏编译失败 | 1 | 将 mutation 返回值先赋给局部常量后断言 |
| 动态 localization helper 编译失败 | 1 | 改为静态 `String(localized:defaultValue:)` 调用 |
