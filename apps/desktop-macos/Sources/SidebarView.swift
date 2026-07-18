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
                    : hovered ? Color.primary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .onHover { hovered = $0 }
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
    let acceptDrop: () -> Bool
    let performDrop: () -> Bool
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
    @State private var dropTargeted = false

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
        .overlay(alignment: .top) {
            if dropTargeted {
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
            delegate: SidebarRowDropDelegate(
                isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 }),
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

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        return perform()
    }
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
                    guard let dragId = model.draggingWorkspaceId else { return false }
                    model.draggingWorkspaceId = nil
                    Task {
                        await model.reorderWorkspace(
                            dragId, toGroup: nil, index: model.ungroupedWorkspaces.count
                        )
                    }
                    return true
                }
        }
        .background(.bar)
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
            connectionDot
            Menu {
                Button("新建分组", systemImage: "folder.badge.plus") {
                    model.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("工作区管理")
            .accessibilityLabel("工作区管理")
            Button {
                Task { await model.createWorkspace() }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("新建工作区")
            .accessibilityLabel("新建工作区")
        }
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    private var connectionDot: some View {
        let (color, help): (Color, String) = switch runtime.state {
        case .connected: (.green, "Runtime 已连接")
        case .connecting: (.orange, "正在连接 Runtime…")
        case .disconnected: (.secondary, "Runtime 未连接")
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    @ViewBuilder
    private var content: some View {
        if hub.entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("未配对任何服务器")
                    .foregroundStyle(.secondary)
                Text("在设置(⌘,)→ 远程 里粘贴配对码。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else if hub.entries.count == 1, let only = hub.entries.first {
            // 单服务器(通常就是本机)不显示分组头,内容直接铺开;多台才需要区分归属
            serverContent(only)
        } else {
            ForEach(hub.entries) { entry in
                serverSection(entry)
            }
        }
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
                Image(systemName: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(entry.server.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
                Task { await model.createWorkspace() }
            }
            .disabled(!entry.connection.connected)
            Button("新建分组") {
                model.activate(serverId: entry.id)
                model.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
            }
            .disabled(!entry.connection.connected)
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
                Task { await model.createWorkspace() }
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
        let expanded = model.expandedWorkspaceGroupIds.contains(group.id)
        let groupWorkspaces = model.workspaces(in: group, on: entry.connection)
        WorkspaceGroupRow(
            snapshot: WorkspaceGroupRowSnapshot(
                id: group.id,
                name: group.name,
                workspaceCount: groupWorkspaces.count,
                isExpanded: expanded
            ),
            actions: WorkspaceGroupRowActions(
                toggle: { model.toggleWorkspaceGroup(group.id) },
                createWorkspace: {
                    model.activate(serverId: entry.id)
                    Task { await model.createWorkspace(in: group.id) }
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
                    model.draggingWorkspaceId != nil && model.draggingWorkspaceServerId == entry.id
                },
                performWorkspaceDrop: {
                    guard let dragId = model.draggingWorkspaceId else { return false }
                    model.draggingWorkspaceId = nil
                    model.activate(serverId: entry.id)
                    Task {
                        await model.reorderWorkspace(
                            dragId, toGroup: group.id, index: group.workspaceIds.count
                        )
                    }
                    return true
                }
            )
        )
        .equatable()

        if expanded {
            if groupWorkspaces.isEmpty {
                Button {
                    model.activate(serverId: entry.id)
                    Task { await model.createWorkspace(in: group.id) }
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
        let expanded = model.expandedWorkspaceIds.contains(workspace.id)
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
                toggleExpand: { model.toggleWorkspace(workspace.id) },
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
                    Task { await model.moveWorkspace(workspace, to: target) }
                },
                beginDrag: {
                    model.draggingWorkspaceId = workspace.id
                    model.draggingWorkspaceServerId = entry.id
                    return NSItemProvider(object: workspace.id as NSString)
                },
                acceptDrop: {
                    model.draggingWorkspaceId != nil && model.draggingWorkspaceId != workspace.id
                        && model.draggingWorkspaceServerId == entry.id
                },
                performDrop: {
                    guard let dragId = model.draggingWorkspaceId else { return false }
                    model.draggingWorkspaceId = nil
                    model.activate(serverId: entry.id)
                    // 落点 = 目标行之前;index 按"移除自己之后"的容器序列计算
                    let container = group.map { model.workspaces(in: $0, on: connection) }
                        ?? model.ungroupedWorkspaces(on: connection)
                    let index = container
                        .filter { $0.id != dragId }
                        .firstIndex { $0.id == workspace.id } ?? container.count
                    Task { await model.reorderWorkspace(dragId, toGroup: group?.id, index: index) }
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
                            Task { _ = await model.openTerminal(in: workspace, inheritFrom: session.id) }
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
