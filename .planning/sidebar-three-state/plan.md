# 左侧栏三态规划

## 目标

桌面端左侧栏支持三种明确状态：

- `wide`：完整工作区管理。
- `compact`：保留快速切换能力的固定宽度图标栏。
- `hidden`：完全释放终端空间，但保留可发现的恢复入口。

三态只改变桌面端呈现，不改变 Runtime、Workspace、Session 或协议模型。

## 范围

- macOS 桌面端左侧栏状态、布局、快捷键和持久化。
- Compact 中的服务器、工作区快速切换和全局动作。
- 旧 `leftSidebarVisible` 快照兼容。
- 针对状态转换、迁移、布局和可访问性的测试。

## 非目标

- 不修改 Runtime 或 `packages/protocol`。
- 不给 Workspace 增加颜色、图标或缩写字段。
- 不在 Compact 中复制会话树、分组管理和拖拽整理。
- 不重构现有 `WorkbenchModel` 的观察模型，也不调整右侧栏。
- 不改变 Workspace 默认导航层级。

## 产品决策

| 状态 | 宽度 | 内容 | 调整宽度 |
| --- | --- | --- | --- |
| Wide | 现有用户宽度，限制为 180–420pt | 完整服务器、分组、工作区和会话视图 | 支持 |
| Compact | 固定 64pt | 服务器状态、工作区快速切换和底部动作 | 不支持 |
| Hidden | 0 | 无侧栏内容；标题栏显示恢复按钮 | 不支持 |

Compact 使用 64pt，而不是照搬 Muxy 的 44pt。Acro 当前侧栏承担 macOS 窗口控制区域，64pt 可以保持红黄绿按钮和现有标题栏布局稳定。

## 状态与持久化

新增值类型：

```swift
enum LeftSidebarPresentation: String, Codable, CaseIterable {
    case wide
    case compact
    case hidden
}
```

`WorkbenchModel` 持有：

- `leftSidebarPresentation`
- `lastVisibleSidebarPresentation`，只允许 `wide` 或 `compact`

状态规则：

- 进入 `wide` 或 `compact` 时同步更新 `lastVisibleSidebarPresentation`。
- 从 `hidden` 恢复时回到 `lastVisibleSidebarPresentation`。
- Wide 的用户宽度继续使用现有 `acro.sidebar.width`。
- Compact 宽度使用代码常量，不污染 Wide 的用户宽度。

快照迁移：

- 新快照写入 `leftSidebarPresentation`。
- 一个兼容周期内继续写入 `leftSidebarVisible`，让旧版本应用仍能读取快照。
- 新版本优先读取 `leftSidebarPresentation`。
- 缺少新字段时，`leftSidebarVisible == true` 映射为 `wide`，`false` 映射为 `hidden`。
- Compact 写入兼容字段时视为可见。

## 交互

### 鼠标

- Wide 底部的侧栏按钮切换到 Compact。
- Compact 底部的侧栏按钮切换到 Wide。
- Hidden 时，终端标题栏左上控制区显示 `sidebar.left` 按钮；点击恢复上次可见状态。
- 三处侧栏按钮都提供菜单，可直接选择 Wide、Compact 或 Hidden。

### 快捷键

- `⌘B`：Hidden 与上次可见状态之间切换，保持现有“显示 / 隐藏左侧栏”语义。
- `⌘⇧B`：Wide 与 Compact 之间切换。
- 命令面板增加三个明确命令：使用宽侧栏、使用窄侧栏、隐藏侧栏。
- 菜单项显示当前状态的选中标记。

快捷键触发的状态变化立即完成。鼠标触发使用最长 160ms 的无弹跳宽度过渡；减少动态效果开启时只做短淡化。

## Wide

Wide 保持当前 `SidebarView` 的信息和管理能力：

- 顶部保留工作区 / 会话视图选择和新建菜单。
- 内容保留本机状态、远程服务器、Workspace Group、Workspace、路径、会话数量和会话行。
- 保留拖拽重排、右键菜单和 Workspace 快捷键提示。
- 底部从“连接服务器 + 设置”调整为“切换 Compact + 连接服务器 + 设置”。

不在本任务中重做 Wide 视觉样式。

## Compact

Compact 是独立呈现，不是缩窄后的 Wide。

### 内容结构

1. 顶部 38pt 保留窗口控制和拖拽区域。
2. 主区域按服务器分段并可滚动。
3. 每台服务器显示一个图标按钮：
   - 本机：`desktopcomputer`
   - 远程：`network`
   - 角标显示连接状态。
4. 服务器下方按当前顺序显示 Workspace 按钮。
5. Workspace 使用名称中第一个有效字符作为本地缩写，不写入 Runtime。
6. Workspace Group 只用间距分段，不显示分组名称。
7. 底部纵向放置：新建、连接服务器、设置、展开 Wide。

### Workspace 按钮

- 固定 36×36pt，外层保持稳定行高。
- 选中状态使用现有强调色背景和清晰的 leading indicator。
- 单击激活对应服务器并选择 Workspace。
- 右键菜单复用 Wide 的新建终端、重命名、移动和删除动作。
- 悬停提示显示“服务器 / 分组 / Workspace”、连接状态和会话数量。
- VoiceOver 标签使用完整名称，不读缩写。
- Compact 不提供拖拽重排；结构管理回到 Wide 完成。

Compact 始终投影 Workspace。`sidebarViewMode == sessions` 只影响 Wide，因为中央标签栏已经承担 Compact 下的会话切换。

## Hidden

- 侧栏不占宽度，不保留透明命中区或边框。
- `TerminalPanesView` 顶部控制区在 Hidden 时提供恢复按钮。
- 恢复按钮不会覆盖红黄绿按钮、标签标题或拖拽区域。
- 右键恢复按钮可直接选择 Wide 或 Compact。

## 代码路径

### 状态与持久化

- `apps/desktop-macos/Sources/WorkbenchModel.swift`
  - 用三态替代 `leftSidebarVisible` 作为内部真源。
  - 增加 hide/restore 和 wide/compact 动作。
- `apps/desktop-macos/Sources/WorkbenchLayoutState.swift`
  - 新增三态字段和旧布尔字段迁移。
- `apps/desktop-macos/Sources/ShortcutSettings.swift`
  - 保留现有 `toggleSidebar`。
  - 新增 Wide / Compact 切换动作和默认快捷键。
- `apps/desktop-macos/Sources/CommandPalette.swift`
  - 增加三个显式状态命令。

### 视图

- `apps/desktop-macos/Sources/WorkbenchView.swift`
  - 根据三态选择 Wide、Compact 或 Hidden 布局。
  - Resizer 只在 Wide 渲染。
- `apps/desktop-macos/Sources/SidebarView.swift`
  - 保持 Wide 容器和现有 snapshot 行边界。
  - 提供 Compact 需要的只读快照和动作投影。
- `apps/desktop-macos/Sources/CompactSidebarView.swift`
  - 新增 Compact 专用视图和紧密绑定的私有行视图。
  - 行只接收不可变值和动作闭包，不持有 RuntimeHub 或 WorkbenchModel。
- `apps/desktop-macos/Sources/TerminalPanesView.swift`
  - Hidden 时显示恢复入口并协调顶部安全区。
- `apps/desktop-macos/Sources/AcroApp.swift`
  - 更新菜单标题和三态命令入口。

不新增 package，也不修改工程结构。桌面端使用 Swift Package，`Sources/` 下新增的 Swift 文件会自动进入 `AcroDesktop` 目标。

## 验证

### 单元测试

- 三态显式选择和切换矩阵。
- Hidden 恢复到最后一次 Wide 或 Compact。
- 旧 `leftSidebarVisible` 快照迁移。
- 新快照同时保留降级兼容字段。
- Compact 宽度固定，Wide 宽度仍受 180–420pt 限制。
- Compact Workspace 缩写、分组顺序和服务器分段投影。
- 快捷键和命令面板动作映射。

### 视觉与交互验证

- 宽窗口、最小窗口和全屏三种环境。
- 本机、单远程和多远程服务器。
- 无 Workspace、长名称、重复首字符和大量 Workspace。
- Wide 拖拽宽度后切换 Compact，再恢复 Wide，原宽度不变。
- Hidden 下标题栏按钮不遮挡窗口按钮、标签和终端输入。
- VoiceOver、键盘焦点、减少动态效果和提高对比度。

### 构建门禁

- `swift test --package-path apps/desktop-macos`
- `pnpm check`
- `git diff --check`
- 使用应用截图或浏览器不可替代的本机窗口检查，确认三态布局没有重叠和空白带。

## 验收标准

1. 用户可以明确进入 Wide、Compact、Hidden 任一状态。
2. `⌘B` 始终只负责隐藏或恢复，不产生不可预测的三态循环。
3. Compact 可以在不展开侧栏的情况下切换服务器和 Workspace。
4. Hidden 始终有可见恢复入口。
5. Wide 的宽度、管理能力和现有拖拽行为不回退。
6. Compact 和 Hidden 不改变 Runtime 数据，也不终止任何会话。
7. 旧布局快照可以无损迁移，降级到旧桌面版本仍能读取可见性。
