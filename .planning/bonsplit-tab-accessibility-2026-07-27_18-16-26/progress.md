# 执行进度：bonsplit-tab-accessibility

- 任务 ID：`bonsplit-tab-accessibility-2026-07-27_18-16-26`
- 创建时间：`2026-07-27_18-16-26`
- 当前状态：`completed`

## 已完成

- 检查正式安装 Beta.31 的 Wide、Compact、Hidden 三种侧栏和双窗格顶部栏。
- 用真实 Accessibility tree 确认标签、关闭与 split action 的名称缺失。
- 对照 Acro、Vendored Bonsplit 与 cmux 源码，确认共享根因与影响范围。
- 创建独立 worktree `fix/bonsplit-tab-accessibility` 并校验项目基线。
- 尝试用 `NSHostingView + NSWindow` 读取 AX tree，确认同进程只能看到空 group，不能作为有效回归测试。
- 删除无论修复与否都会失败的假测试，保留正式应用真实 AX tree为硬验收。
- 将标签 AX 语义移到 `TabBarView` 最终 drag/drop 包装层，保留动态标题、状态和 selected trait。
- close 按钮增加本地化名称与稳定 identifier；split action 两条渲染路径共用 tooltip label。
- 标签标题和装饰图标从子 AX 树隐藏，避免与根标签元素重复朗读；close/audio/zoom 继续独立暴露。
- Acro 的 new terminal/new browser/split right/split down 文案接入 en/ja/zh-Hans 本地化。
- 标签状态 Loading/Pinned/Unread/Modified/Zoomed 和 Exit Zoom 接入 Bonsplit 本地化。
- 简体中文补齐静音、取消静音、已静音和 SSH 连接状态，避免辅助功能文案回退英文。
- 最新 Beta.32 候选的真实系统 AX 树确认标签、close 和 split action 名称、状态与 identifier 正确。

## 进行中

- 无。

## 修改文件

- `.planning/bonsplit-tab-accessibility-2026-07-27_18-16-26/`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `apps/desktop-macos/Vendor/bonsplit/Sources/Bonsplit/Resources/*/Localizable.strings`
- `apps/desktop-macos/Sources/TerminalPaneController.swift`
- `apps/desktop-macos/Localization/*/Localizable.strings`

## 验证结果

| 检查 | 结果 | 状态 |
|---|---|---|
| Beta.31 真实截图 | Wide/Compact/Hidden 稳定布局正常 | 通过 |
| Beta.31 Accessibility tree | 标签、close、普通 split actions 缺少明确名称 | 已复现 |
| Acro/cmux/Bonsplit 源码对照 | 根因位于 Bonsplit 最终组合层，cmux 同样不完整 | 通过 |
| 同进程 AX harness | 仅返回空 group，无法区分修复前后 | 不适用，已删除假测试 |
| Bonsplit 完整测试 | 205 项通过 | 通过 |
| Acro 完整测试 | XCTest 86 项、Swift Testing 63 项通过 | 通过 |
| Acro release build | 构建完成 | 通过；仅仓库既有 warning |
| 本地化语法 | 6 个 touched `.strings` 全部通过 `plutil -lint` | 通过 |
| 新增 key 覆盖 | 本轮新增 key 在 en/ja/zh-Hans 均存在 | 通过 |
| Beta.32 候选 Accessibility tree | 动态标签名、selected、独立 Close Tab、New Terminal、Split Right、Split Down 与稳定 ID 均存在 | 通过 |
| 标签点击/拖拽/split 命中测试 | `mouseClickDragAndSplitButtonUseTheirFullRenderedHitTargets` 通过 | 通过 |
| 会话保持 | 热替换仅重启 UI/runtime，daemon PID 1151 保持不变 | 通过 |

## 错误与恢复

| 错误 | 尝试 | 解决方式 |
|---|---:|---|
| 紧凑侧栏截图空白 | 1 | 等待动画结束后复查，确认稳定态正确 |
| AX 单测无论修复与否都会失败 | 1 | 删除假测试，改用正式候选应用的真实系统 AX tree |
