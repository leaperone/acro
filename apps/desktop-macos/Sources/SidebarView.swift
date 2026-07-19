// 侧边栏:可折叠分组 + 工作区 + 会话行,支持拖拽重排与 ⌘ 数字提示。
// 行结构执行 cmux 的 snapshot 边界规则(GPL-3.0-or-later, Copyright (c)
// 2024-present Manaflow, Inc.):ForEach 之下的行视图不持有任何 ObservableObject,
// 只接收 Equatable 值快照与闭包动作包,配合 .equatable() 跳过无关重绘。
// 拖拽重排、⌘长按数字提示同样取自 cmux 的侧边栏交互。

import SwiftUI
import UniformTypeIdentifiers

struct SidebarRowSurface: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                selected
                    ? Color.accentColor.opacity(0.18)
                    : hovered ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .onHover { hovered = $0 }
    }
}

// footer ghost 图标按钮:复刻 cmux 的 house 约定——透明底,hover/pressed 才浮出
// Color.primary 的柔和填充(0 / 0.08 / 0.16 三档),圆角 8。
struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        private var fillOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.16 }
            return hovered ? 0.08 : 0
        }

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

// ---- 快照与动作包 ----

struct SidebarMoveTarget: Equatable {
    let id: String
    let name: String
    let disabled: Bool
}

struct WorkspaceGroupRowSnapshot: Equatable {
    let id: String
    let name: String
    let workspaceCount: Int
    let isExpanded: Bool
}

struct WorkspaceGroupRowActions {
    let toggle: () -> Void
    let createWorkspace: () -> Void
    let rename: () -> Void
    let dissolve: () -> Void
    let acceptWorkspaceDrop: () -> Bool
    let performWorkspaceDrop: () -> Bool
}

struct WorkspaceRowSnapshot: Equatable {
    let id: String
    let name: String
    let isSelected: Bool
    let sessionCount: Int
    let showsChevron: Bool
    let isExpanded: Bool
    let isInGroup: Bool
    let shortcutHint: String?
    // cmux 式副行:工作区的既定路径(第一个存活终端的目录,~ 缩写)
    let pathLabel: String?
    let moveTargets: [SidebarMoveTarget]
}

struct WorkspaceRowActions {
    let select: () -> Void
    let toggleExpand: () -> Void
    let newTerminal: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let moveToGroup: (String?) -> Void
    let beginDrag: () -> NSItemProvider
    let acceptDrop: (SidebarWorkspaceDropEdge) -> Bool
    let performDrop: (SidebarWorkspaceDropEdge) -> Bool
}

enum SidebarWorkspaceDropEdge: Equatable {
    case top
    case bottom

    static func resolve(locationY: CGFloat, height: CGFloat) -> Self {
        locationY < max(height, 1) / 2 ? .top : .bottom
    }
}

enum SidebarWorkspaceDropPlanner {
    static func insertionIndex(
        draggedWorkspaceId: String,
        targetWorkspaceId: String,
        orderedWorkspaceIds: [String],
        edge: SidebarWorkspaceDropEdge
    ) -> Int? {
        guard draggedWorkspaceId != targetWorkspaceId else { return nil }
        let remaining = orderedWorkspaceIds.filter { $0 != draggedWorkspaceId }
        guard let targetIndex = remaining.firstIndex(of: targetWorkspaceId) else { return nil }
        let insertionIndex = targetIndex + (edge == .bottom ? 1 : 0)
        guard orderedWorkspaceIds.firstIndex(of: draggedWorkspaceId) != insertionIndex else {
            return nil
        }
        return insertionIndex
    }
}

struct SessionRowSnapshot: Equatable {
    let id: String
    let title: String
    let cwd: String
    let alive: Bool
    let isSelected: Bool
}

struct SessionRowActions {
    let show: () -> Void
    let newSibling: () -> Void
    let terminate: () -> Void
}

// ---- 行视图(snapshot 边界之下,不持 store) ----

struct WorkspaceGroupRow: View, Equatable {
    let snapshot: WorkspaceGroupRowSnapshot
    let actions: WorkspaceGroupRowActions
    @State private var hovered = false
    @State private var dropTargeted = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: actions.toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(snapshot.isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: snapshot.isExpanded)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isExpanded ? "折叠分组" : "展开分组")

            Button(action: actions.toggle) {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(snapshot.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if snapshot.workspaceCount > 0 {
                        Text("\(snapshot.workspaceCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.name)
            .accessibilityValue(snapshot.isExpanded ? "已展开" : "已折叠")

            Button(action: actions.createWorkspace) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .help("在分组中新建工作区")
            .accessibilityLabel("在 \(snapshot.name) 新建工作区")
        }
        .padding(.horizontal, 6)
        .background(
            dropTargeted ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .modifier(SidebarRowSurface(selected: false))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("新建工作区", action: actions.createWorkspace)
            Divider()
            Button("重命名", action: actions.rename)
            Button("解散分组", role: .destructive, action: actions.dissolve)
        }
        .onDrop(
            of: [UTType.text],
            delegate: SidebarRowDropDelegate(
                isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 }),
                canAccept: actions.acceptWorkspaceDrop,
                perform: actions.performWorkspaceDrop
            )
        )
    }
}

struct WorkspaceRow: View, Equatable {
    let snapshot: WorkspaceRowSnapshot
    let actions: WorkspaceRowActions
    @State private var hovered = false
    @State private var dropEdge: SidebarWorkspaceDropEdge?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        HStack(spacing: 4) {
            if snapshot.showsChevron {
                Button(action: actions.toggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(snapshot.isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.15), value: snapshot.isExpanded)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snapshot.isExpanded ? "折叠工作区" : "展开工作区")
            }

            Button(action: actions.select) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(snapshot.isSelected ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if let pathLabel = snapshot.pathLabel {
                            // cmux 分支·目录副行的最小版:既定路径,~ 缩写,中间截断
                            Text(pathLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 6)
                    if snapshot.sessionCount > 0 {
                        Text("\(snapshot.sessionCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: snapshot.pathLabel == nil ? 32 : 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.name)

            Button(action: actions.newTerminal) {
                Image(systemName: "plus")
            }
            .frame(width: 24, height: 24)
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .help("新建终端")
            .accessibilityLabel("在 \(snapshot.name) 新建终端")
        }
        .padding(.horizontal, 6)
        .modifier(SidebarRowSurface(selected: snapshot.isSelected))
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            if dropEdge != nil {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            // ⌘ 长按显示的数字提示(cmux sidebarShortcutHintOverlay)
            if let hint = snapshot.shortcutHint {
                ShortcutHintPill(text: hint)
                    .padding(.top, 7)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("新建终端", action: actions.newTerminal)
            Divider()
            if !snapshot.moveTargets.isEmpty {
                Menu("移动到分组") {
                    ForEach(snapshot.moveTargets, id: \.id) { target in
                        Button(target.name) { actions.moveToGroup(target.id) }
                            .disabled(target.disabled)
                    }
                }
            }
            if snapshot.isInGroup {
                Button("移出分组") { actions.moveToGroup(nil) }
            }
            if !snapshot.moveTargets.isEmpty {
                Divider()
            }
            Button("重命名", action: actions.rename)
            Button("删除工作区", role: .destructive, action: actions.delete)
        }
        .onDrag(actions.beginDrag)
        .onDrop(
            of: [UTType.text],
            delegate: SidebarWorkspaceRowDropDelegate(
                edge: Binding(get: { dropEdge }, set: { dropEdge = $0 }),
                height: snapshot.pathLabel == nil ? 32 : 40,
                canAccept: actions.acceptDrop,
                perform: actions.performDrop
            )
        )
    }
}

struct SessionRow: View, Equatable {
    let snapshot: SessionRowSnapshot
    let actions: SessionRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        Button(action: actions.show) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                    .foregroundStyle(snapshot.isSelected ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.cwd)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(snapshot.alive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarRowSurface(selected: snapshot.isSelected))
        .disabled(!snapshot.alive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.alive ? "运行中" : "已结束")
        .contextMenu {
            Button("在同一目录新建终端", action: actions.newSibling)
            Divider()
            Button("关闭终端", role: .destructive, action: actions.terminate)
        }
    }
}

private struct SidebarRowDropDelegate: DropDelegate {
    let isTargeted: Binding<Bool>
    let canAccept: () -> Bool
    let perform: () -> Bool

    func validateDrop(info: DropInfo) -> Bool { canAccept() }

    func dropEntered(info: DropInfo) {
        if canAccept() { isTargeted.wrappedValue = true }
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canAccept() ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        return perform()
    }
}

private struct SidebarWorkspaceRowDropDelegate: DropDelegate {
    let edge: Binding<SidebarWorkspaceDropEdge?>
    let height: CGFloat
    let canAccept: (SidebarWorkspaceDropEdge) -> Bool
    let perform: (SidebarWorkspaceDropEdge) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        canAccept(.top) || canAccept(.bottom)
    }

    func dropEntered(info: DropInfo) {
        updateEdge(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateEdge(info)
        return DropProposal(operation: edge.wrappedValue == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        edge.wrappedValue = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let resolved = resolvedEdge(info)
        edge.wrappedValue = nil
        return canAccept(resolved) && perform(resolved)
    }

    private func updateEdge(_ info: DropInfo) {
        let resolved = resolvedEdge(info)
        edge.wrappedValue = canAccept(resolved) ? resolved : nil
    }

    private func resolvedEdge(_ info: DropInfo) -> SidebarWorkspaceDropEdge {
        .resolve(locationY: info.location.y, height: height)
    }
}

// SwiftUI onDrag 没有结束回调;provider 销毁时清理 ESC 取消和拖出窗口的残留状态。
private final class WorkspaceDragItemProvider: NSItemProvider {
    var onEnd: (() -> Void)?
    deinit { onEnd?() }
}

// ---- 侧边栏容器(snapshot 边界之上,持有 model 并投影快照) ----

struct SidebarView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    // hub 转发各子连接的变化;不观察它,其他服务器的数据更新不会触发重绘
    @ObservedObject var hub: RuntimeHub
    // 多主机:所有已配对服务器同时在线,每台一个手风琴段,各自实时显示各自的工作区。
    // 折叠状态仅本地;选择/操作某台服务器的内容前先 activate 把动作路由过去。
    @State private var collapsedServerIds: Set<String> = []
    // 服务器接入与编辑(共享配对码的生成仍在设置 → 远程)
    @State private var connectSheetPresented = false
    @State private var editingServerId: EditingServerId?
    @State private var pendingServerRemoval: ServerEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)

            // 底部空白区:接住"拖到未分组末尾"
            Color.clear
                .frame(height: 24)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    guard let payload = model.draggingWorkspace,
                          let entry = hub.entries.first(where: { $0.id == payload.serverId })
                    else { return false }
                    model.draggingWorkspace = nil
                    model.activate(serverId: payload.serverId)
                    model.requestReorderWorkspace(
                        payload.workspaceId,
                        toGroup: nil,
                        index: model.ungroupedWorkspaces(on: entry.connection).count
                    )
                    return true
                }

            Divider()
            sidebarFooter
        }
        .background(.bar)
        .sheet(isPresented: $connectSheetPresented) {
            ConnectServerSheet(hub: hub)
        }
        .sheet(item: $editingServerId) { editing in
            EditServerSheet(serverId: editing.id, hub: hub)
        }
        .confirmationDialog(
            "移除服务器「\(pendingServerRemoval?.name ?? "")」?",
            isPresented: Binding(
                get: { pendingServerRemoval != nil },
                set: { if !$0 { pendingServerRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除(不影响服务器上的会话)", role: .destructive) {
                guard let server = pendingServerRemoval else { return }
                pendingServerRemoval = nil
                ServerDirectory.remove(server.id, hub: hub)
                // 删的是当前查看的服务器时,选中态立即回落,不留悬空 id
                model.reconcileLayoutState()
            }
            Button("取消", role: .cancel) { pendingServerRemoval = nil }
        } message: {
            Text("只删除本机的连接凭据;服务器上的工作区与终端不受影响,可重新配对接入。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            WindowDragHandle()
                .frame(width: 62)
                .frame(maxHeight: .infinity) // 红绿灯区
            WindowDragHandle()
                .frame(minWidth: 4, maxWidth: .infinity, maxHeight: .infinity)
            Picker("侧边栏视图", selection: $model.sidebarViewMode) {
                ForEach(SidebarViewMode.allCases) { mode in
                    Image(systemName: mode.symbol)
                        .accessibilityLabel(mode.title)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 64)
            .help("切换工作区或会话视图")
            // 新建拆分按钮:单击直接新建工作区(保留右上角肌肉记忆),按住/展开菜单可选新建分组。
            // 取代原来的「三点圈菜单 + 独立加号」两块。
            Menu {
                Button("新建工作区", systemImage: "square.stack.3d.up.badge.plus") {
                    model.requestCreateWorkspace()
                }
                Button("新建分组", systemImage: "folder.badge.plus") {
                    model.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            } primaryAction: {
                model.requestCreateWorkspace()
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建工作区(按住可新建分组)")
            .accessibilityLabel("新建")
        }
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    // 连接状态点:绿=已连接,橙=连接中,灰=未连接。顶栏不再放全局 dot,
    // 状态下沉到每台服务器头部(远程 section 头与本地状态带各自复用)。
    private func statusDot(_ state: RuntimeConnection.ConnectionState) -> some View {
        let (color, help): (Color, String) = switch state {
        case .connected: (.green, "已连接")
        case .connecting: (.orange, "连接中…")
        case .disconnected: (.secondary, "未连接")
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    // 本地优先:本机内容(回环入口条目)永远无头铺在最前;
    // 每台远程服务器一个手风琴段。接入/编辑服务器都在这里完成。
    @ViewBuilder
    private var content: some View {
        let locals = hub.entries.filter { $0.server.isLocal }
        let remotes = hub.entries.filter { !$0.server.isLocal }
        if hub.entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("本机 Runtime 未就绪")
                    .foregroundStyle(.secondary)
                Text("正在自动拉起本地服务;远程服务器用底栏的接入按钮连接。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        ForEach(locals) { entry in
            localStatusBand(entry)
            serverContent(entry)
        }
        if !locals.isEmpty && !remotes.isEmpty {
            Divider()
                .padding(.vertical, 4)
        }
        ForEach(remotes) { entry in
            serverSection(entry)
        }
    }

    // 本机状态带:本地 runtime 无手风琴头,单独补一条不可折叠的轻量状态行,
    // 与远程 section 头同层级呈现连接状态(顶栏 dot 删除后由它 + 远程头承接)。
    private func localStatusBand(_ entry: RuntimeHub.Entry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("本机")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            statusDot(entry.connection.state)
            Text(localStateLabel(entry.connection.state))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func localStateLabel(_ state: RuntimeConnection.ConnectionState) -> String {
        switch state {
        case .connected: "就绪"
        case .connecting: "连接中…"
        case .disconnected: "未就绪"
        }
    }

    // 底部功能条:承接不隶属某台服务器的低频全局动作(接入服务器 / 设置),
    // 对齐 cmux 的 footer 抽屉惯例,让内容列表底部更干净。固定钉底不随列表滚动。
    private var sidebarFooter: some View {
        HStack(spacing: 4) {
            Button {
                connectSheetPresented = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .help("粘贴另一台服务器的配对码接入")
            .accessibilityLabel("连接服务器")
            Spacer(minLength: 0)
            Button {
                model.requestOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .help("打开设置")
            .accessibilityLabel("设置")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    // 每台服务器一个手风琴段,内容来自它自己的连接,同时在线互不影响
    @ViewBuilder
    private func serverSection(_ entry: RuntimeHub.Entry) -> some View {
        let expanded = !collapsedServerIds.contains(entry.id)
        let isSelected = model.selectedServerId == entry.id
        Button {
            if expanded {
                collapsedServerIds.insert(entry.id)
            } else {
                collapsedServerIds.remove(entry.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(entry.server.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                statusDot(entry.connection.state)
                Text(pathLabel(entry.connection))
                    .font(.caption2)
                    .foregroundStyle(entry.connection.connected ? Color.green : Color.orange)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.connection.connected ? "展开/收起 \(entry.server.name)" : "\(entry.server.name) 未连接,自动重试中")
        .contextMenu {
            // 服务器级创建入口:动作先 activate,保证 RPC 落到这台服务器
            Button("新建工作区") {
                model.activate(serverId: entry.id)
                model.requestCreateWorkspace()
            }
            .disabled(!entry.connection.connected)
            Button("新建分组") {
                model.activate(serverId: entry.id)
                model.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
            }
            .disabled(!entry.connection.connected)
            Divider()
            Button("编辑服务器…") { editingServerId = EditingServerId(id: entry.id) }
            Button("移除服务器", role: .destructive) { pendingServerRemoval = entry.server }
            Divider()
            Button("远程设置…") { model.requestOpenSettings() }
        }

        if expanded {
            serverContent(entry)
                .padding(.leading, 4)
        }
    }

    private func pathLabel(_ connection: RuntimeConnection) -> String {
        switch connection.state {
        case .connected:
            guard let endpoint = connection.connectedEndpoint else { return "已连接" }
            return EndpointKind.classify(endpoint) == .lan ? "局域网" : "公网"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        }
    }

    @ViewBuilder
    private func serverContent(_ entry: RuntimeHub.Entry) -> some View {
        let connection = entry.connection
        if connection.workspaceGroups.isEmpty && connection.workspaces.isEmpty {
            Button {
                model.activate(serverId: entry.id)
                model.requestCreateWorkspace()
            } label: {
                Label(
                    connection.connected ? "新建工作区" : "等待连接…",
                    systemImage: connection.connected
                        ? "square.stack.3d.up.badge.plus" : "wifi.exclamationmark"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!connection.connected)
        } else {
            ForEach(connection.workspaceGroups) { group in
                groupSection(group, entry: entry)
            }
            let ungrouped = model.ungroupedWorkspaces(on: connection)
            if !ungrouped.isEmpty {
                if !connection.workspaceGroups.isEmpty {
                    Text("未分组")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                ForEach(ungrouped) { workspace in
                    workspaceSection(workspace, group: nil, indent: 0, entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: WorkspaceGroup, entry: RuntimeHub.Entry) -> some View {
        let expanded = model.expandedWorkspaceGroupIds.contains(ScopedResourceID(
            serverId: entry.id,
            resourceId: group.id
        ))
        let groupWorkspaces = model.workspaces(in: group, on: entry.connection)
        WorkspaceGroupRow(
            snapshot: WorkspaceGroupRowSnapshot(
                id: group.id,
                name: group.name,
                workspaceCount: groupWorkspaces.count,
                isExpanded: expanded
            ),
            actions: WorkspaceGroupRowActions(
                toggle: { model.toggleWorkspaceGroup(group.id, serverId: entry.id) },
                createWorkspace: {
                    model.activate(serverId: entry.id)
                    model.requestCreateWorkspace(in: group.id)
                },
                rename: {
                    model.activate(serverId: entry.id)
                    model.presentWorkspaceGroupEditor(workspaceGroupId: group.id, name: group.name)
                },
                dissolve: {
                    model.activate(serverId: entry.id)
                    model.pendingWorkspaceGroupRemoval = group
                },
                acceptWorkspaceDrop: {
                    model.draggingWorkspace?.serverId == entry.id
                },
                performWorkspaceDrop: {
                    guard let payload = model.draggingWorkspace,
                          payload.serverId == entry.id else { return false }
                    model.draggingWorkspace = nil
                    model.activate(serverId: entry.id)
                    model.requestReorderWorkspace(
                        payload.workspaceId, toGroup: group.id, index: group.workspaceIds.count)
                    return true
                }
            )
        )
        .equatable()

        if expanded {
            if groupWorkspaces.isEmpty {
                Button {
                    model.activate(serverId: entry.id)
                    model.requestCreateWorkspace(in: group.id)
                } label: {
                    Label("新建工作区", systemImage: "square.stack.3d.up.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            } else {
                ForEach(groupWorkspaces) { workspace in
                    workspaceSection(workspace, group: group, indent: 14, entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceSection(
        _ workspace: Workspace,
        group: WorkspaceGroup?,
        indent: CGFloat,
        entry: RuntimeHub.Entry
    ) -> some View {
        let connection = entry.connection
        let expanded = model.expandedWorkspaceIds.contains(ScopedResourceID(
            serverId: entry.id,
            resourceId: workspace.id
        ))
        let workspaceSessions = model.sessions(in: workspace, on: connection)
        let currentGroup = model.workspaceGroup(containing: workspace.id, on: connection)
        let isSelectedServer = model.selectedServerId == entry.id
        WorkspaceRow(
            snapshot: WorkspaceRowSnapshot(
                id: workspace.id,
                name: workspace.name,
                isSelected: isSelectedServer && model.selectedWorkspaceId == workspace.id
                    && (model.sidebarViewMode == .workspaces || model.selectedSessionId == nil),
                sessionCount: workspaceSessions.count,
                showsChevron: model.sidebarViewMode == .sessions,
                isExpanded: expanded,
                isInGroup: currentGroup != nil,
                shortcutHint: model.cmdHeld && isSelectedServer
                    ? model.workspaceShortcutDigit(workspace.id).map { "⌘\($0)" }
                    : nil,
                pathLabel: workspaceSessions.first.map { SidebarPath.abbreviate($0.cwd) },
                moveTargets: connection.workspaceGroups.map {
                    SidebarMoveTarget(id: $0.id, name: $0.name, disabled: $0.id == currentGroup?.id)
                }
            ),
            actions: WorkspaceRowActions(
                select: {
                    model.activate(serverId: entry.id)
                    model.selectWorkspace(workspace)
                },
                toggleExpand: { model.toggleWorkspace(workspace.id, serverId: entry.id) },
                newTerminal: {
                    model.activate(serverId: entry.id)
                    model.requestNewTerminal(in: workspace)
                },
                rename: {
                    model.activate(serverId: entry.id)
                    model.presentWorkspaceRename(workspaceId: workspace.id, name: workspace.name)
                },
                delete: {
                    model.activate(serverId: entry.id)
                    model.pendingWorkspaceDeletion = workspace
                },
                moveToGroup: { groupId in
                    model.activate(serverId: entry.id)
                    let target = connection.workspaceGroups.first { $0.id == groupId }
                    model.requestMoveWorkspace(workspace, to: target)
                },
                beginDrag: {
                    let payload = WorkspaceDragPayload(workspaceId: workspace.id, serverId: entry.id)
                    model.draggingWorkspace = payload
                    let provider = WorkspaceDragItemProvider(object: workspace.id as NSString)
                    provider.onEnd = { Task { @MainActor in model.endWorkspaceDrag(payload) } }
                    return provider
                },
                acceptDrop: { edge in
                    guard let payload = model.draggingWorkspace,
                          payload.serverId == entry.id else { return false }
                    let container = group.map { model.workspaces(in: $0, on: connection) }
                        ?? model.ungroupedWorkspaces(on: connection)
                    return SidebarWorkspaceDropPlanner.insertionIndex(
                        draggedWorkspaceId: payload.workspaceId,
                        targetWorkspaceId: workspace.id,
                        orderedWorkspaceIds: container.map(\.id),
                        edge: edge
                    ) != nil
                },
                performDrop: { edge in
                    guard let payload = model.draggingWorkspace,
                          payload.serverId == entry.id else { return false }
                    let container = group.map { model.workspaces(in: $0, on: connection) }
                        ?? model.ungroupedWorkspaces(on: connection)
                    guard let index = SidebarWorkspaceDropPlanner.insertionIndex(
                        draggedWorkspaceId: payload.workspaceId,
                        targetWorkspaceId: workspace.id,
                        orderedWorkspaceIds: container.map(\.id),
                        edge: edge
                    ) else { return false }
                    model.draggingWorkspace = nil
                    model.activate(serverId: entry.id)
                    model.requestReorderWorkspace(
                        payload.workspaceId, toGroup: group?.id, index: index)
                    return true
                }
            )
        )
        .equatable()
        .padding(.leading, indent)

        if model.sidebarViewMode == .sessions && expanded {
            ForEach(workspaceSessions) { session in
                SessionRow(
                    snapshot: SessionRowSnapshot(
                        id: session.id,
                        title: model.sessionDisplayName(session, on: connection),
                        cwd: SidebarPath.abbreviate(session.cwd),
                        alive: session.alive,
                        isSelected: isSelectedServer && model.selectedSessionId == session.id
                    ),
                    actions: SessionRowActions(
                        show: {
                            model.activate(serverId: entry.id)
                            model.showSession(session)
                        },
                        newSibling: {
                            model.activate(serverId: entry.id)
                            model.requestNewTerminal(in: workspace, inheritFrom: session.id)
                        },
                        terminate: {
                            model.activate(serverId: entry.id)
                            model.pendingSessionTermination = session
                        }
                    )
                )
                .equatable()
                .padding(.leading, indent + 16)
            }
            if workspaceSessions.isEmpty {
                Button {
                    model.activate(serverId: entry.id)
                    model.requestNewTerminal(in: workspace)
                } label: {
                    Label("新建终端", systemImage: "terminal.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, indent + 22)
            }
        }
    }
}


// 路径缩写(cmux SidebarPathFormatter 的最小版,GPL-3.0-or-later,
// Copyright (c) 2024-present Manaflow, Inc.):把家目录前缀替换为 ~。
// 路径来自远端服务器,不能用本机 NSHomeDirectory();按 /Users/<u> 与 /home/<u> 启发式处理
enum SidebarPath {
    static func abbreviate(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] {
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }
}
