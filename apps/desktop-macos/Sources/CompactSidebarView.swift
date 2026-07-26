// Compact 左侧栏：固定宽度的服务器 / 工作区快速切换轨道。
// 结构管理、会话树和破坏性操作保留在完整侧边栏。

import SwiftUI
import UniformTypeIdentifiers

enum CompactSidebarLayout {
    static let width: CGFloat = 64
    static let headerHeight: CGFloat = 38
    static let itemWidth: CGFloat = 52
    static let itemHeight: CGFloat = 44
    static let serverSectionWidth: CGFloat = 56
    static let serverSectionSpacing: CGFloat = 10
    static let serverSectionCornerRadius: CGFloat = 12
    static let serverIconSize: CGFloat = 36
    static let workspaceIconSize: CGFloat = 32
}

enum CompactSidebarIdentity {
    static func mark(for name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "•" : String(value.prefix(2)).uppercased()
    }

    static func colorIndex(for id: String, paletteCount: Int = 8) -> Int {
        guard paletteCount > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }
}

struct CompactSidebarSection: Identifiable, Equatable {
    let id: String
    let groupId: String?
    let name: String?
    let workspaces: [Workspace]
}

enum CompactSidebarProjection {
    static func sections(
        groups: [WorkspaceGroup],
        workspaces: [Workspace]
    ) -> [CompactSidebarSection] {
        let byId = Dictionary(
            workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sections = groups.compactMap { group -> CompactSidebarSection? in
            let values = group.workspaceIds.compactMap { byId[$0] }
            guard !values.isEmpty else { return nil }
            return CompactSidebarSection(
                id: "group:\(group.id)",
                groupId: group.id,
                name: group.name,
                workspaces: values
            )
        }
        let groupedIds = Set(groups.flatMap(\.workspaceIds))
        let ungrouped = workspaces.filter { !groupedIds.contains($0.id) }
        if !ungrouped.isEmpty {
            sections.append(CompactSidebarSection(
                id: "ungrouped",
                groupId: nil,
                name: nil,
                workspaces: ungrouped
            ))
        }
        return sections
    }
}

extension LeftSidebarPresentation {
    var title: String {
        switch self {
        case .wide: "完整"
        case .compact: "紧凑"
        case .hidden: "隐藏"
        }
    }

    var symbol: String {
        switch self {
        case .wide: "sidebar.left"
        case .compact: "sidebar.squares.left"
        case .hidden: "sidebar.left"
        }
    }
}

struct SidebarPresentationCommands: View {
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        ForEach(LeftSidebarPresentation.allCases) { presentation in
            Button {
                model.setLeftSidebarPresentation(presentation)
            } label: {
                Label(
                    presentation.title,
                    systemImage: presentation == model.leftSidebarPresentation
                        ? "checkmark.circle.fill" : presentation.symbol
                )
            }
        }
    }
}

struct SidebarPresentationMenuButton: View {
    @ObservedObject var model: WorkbenchModel

    private var help: String {
        "切换为\(model.leftSidebarPresentation.next.title)侧边栏（按住选择模式）"
    }

    var body: some View {
        Menu {
            SidebarPresentationCommands(model: model)
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 22, height: 22)
        } primaryAction: {
            model.cycleLeftSidebarPresentation()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SidebarFooterIconButtonStyle())
        .help(help)
        .accessibilityLabel("切换左侧栏模式")
        .accessibilityValue(model.leftSidebarPresentation.title)
        .contextMenu {
            SidebarPresentationCommands(model: model)
        }
    }
}

struct CompactSidebarView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var hub: RuntimeHub
    @State private var connectSheetPresented = false

    private static let palette: [Color] = [
        .blue, .purple, .orange, .pink, .teal, .indigo, .green, .red,
    ]

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: CompactSidebarLayout.headerHeight)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: CompactSidebarLayout.serverSectionSpacing) {
                        if hub.entries.isEmpty {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                                .frame(width: CompactSidebarLayout.itemWidth, height: 36)
                                .help("Runtime 尚未就绪")
                                .accessibilityLabel("Runtime 尚未就绪")
                        }
                        ForEach(SidebarServerProjection.entries(hub.entries)) { entry in
                            RuntimeConnectionScope(connection: entry.connection) { connection in
                                serverSection(entry)
                                    .onChange(of: connection.workspaces.map(\.id).sorted()) { _, _ in
                                        scrollToSelection(proxy)
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedWorkspaceScrollId, initial: true) { _, _ in
                    scrollToSelection(proxy)
                }
                .onChange(of: workspaceMembershipIds) { _, _ in
                    scrollToSelection(proxy)
                }
            }

            Divider()
            footer
        }
        .frame(width: CompactSidebarLayout.width)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .sheet(isPresented: $connectSheetPresented) {
            ConnectServerSheet(hub: hub)
        }
    }

    private var selectedWorkspaceScrollId: String? {
        guard let serverId = model.selectedServerId,
              let workspaceId = model.selectedWorkspaceId else { return nil }
        return workspaceScrollId(serverId: serverId, workspaceId: workspaceId)
    }

    private var workspaceMembershipIds: [String] {
        hub.entries.flatMap { entry in
            entry.connection.workspaces.map {
                workspaceScrollId(serverId: entry.id, workspaceId: $0.id)
            }
        }.sorted()
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selectedWorkspaceScrollId else { return }
        proxy.scrollTo(selectedWorkspaceScrollId)
    }

    private func workspaceScrollId(serverId: String, workspaceId: String) -> String {
        "workspace:\(serverId):\(workspaceId)"
    }

    private func serverSection(_ entry: RuntimeHub.Entry) -> some View {
        let sections = CompactSidebarProjection.sections(
            groups: entry.connection.workspaceGroups,
            workspaces: entry.connection.workspaces
        )
        let color = Self.palette[CompactSidebarIdentity.colorIndex(for: entry.id)]
        let isSelected = model.selectedServerId == entry.id
        return VStack(spacing: 6) {
            CompactSidebarServerButton(
                snapshot: CompactSidebarServerSnapshot(
                    id: entry.id,
                    name: entry.server.name,
                    initial: CompactSidebarIdentity.mark(for: entry.server.name),
                    isLocal: entry.server.isLocal,
                    isSelected: isSelected,
                    state: entry.connection.state
                ),
                color: color,
                select: { model.activate(serverId: entry.id) },
                createWorkspace: {
                    model.activate(serverId: entry.id)
                    model.requestCreateWorkspace()
                },
                useWideSidebar: { model.setLeftSidebarPresentation(.wide) },
                beginDrag: entry.server.isLocal ? nil : {
                    beginServerDrag(entry)
                },
                acceptDrop: { edge in
                    serverInsertionIndex(target: entry, edge: edge) != nil
                },
                performDrop: { edge in
                    performServerDrop(target: entry, edge: edge)
                }
            )

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(spacing: 6) {
                    ForEach(section.workspaces) { workspace in
                        compactWorkspaceButton(
                            workspace,
                            section: section,
                            entry: entry
                        )
                    }
                }
                .padding(.top, index == 0 ? 0 : 12)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Divider()
                            .frame(width: 18)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: CompactSidebarLayout.serverSectionWidth)
        .background(
            color.opacity(isSelected ? 0.10 : 0.06),
            in: RoundedRectangle(
                cornerRadius: CompactSidebarLayout.serverSectionCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: CompactSidebarLayout.serverSectionCornerRadius,
                style: .continuous
            )
            .stroke(color.opacity(isSelected ? 0.55 : 0.28), lineWidth: isSelected ? 1.5 : 1)
        }
    }

    private func compactWorkspaceButton(
        _ workspace: Workspace,
        section: CompactSidebarSection,
        entry: RuntimeHub.Entry
    ) -> some View {
        let sessions = model.sessions(in: workspace, on: entry.connection)
        let scopedId = workspaceScrollId(serverId: entry.id, workspaceId: workspace.id)
        return CompactSidebarWorkspaceButton(
            snapshot: CompactSidebarWorkspaceSnapshot(
                id: scopedId,
                name: workspace.name,
                initial: CompactSidebarIdentity.mark(for: workspace.name),
                serverName: entry.server.name,
                groupName: section.name,
                sessionCount: sessions.count,
                isSelected: model.selectedServerId == entry.id
                    && model.selectedWorkspaceId == workspace.id,
                canCreateTerminal: entry.connection.connected,
                shortcutHint: model.cmdHeld && model.selectedServerId == entry.id
                    ? model.workspaceShortcutDigit(workspace.id).map { "⌘\($0)" }
                    : nil
            ),
            select: {
                model.activate(serverId: entry.id)
                model.selectWorkspace(workspace)
            },
            newTerminal: {
                model.activate(serverId: entry.id)
                model.requestNewTerminal(in: workspace)
            },
            showInWideSidebar: {
                model.activate(serverId: entry.id)
                model.selectWorkspace(workspace)
                model.setLeftSidebarPresentation(.wide)
            },
            beginDrag: {
                model.draggingServer = nil
                let payload = WorkspaceDragPayload(
                    workspaceId: workspace.id, serverId: entry.id)
                model.draggingWorkspace = payload
                let provider = SidebarDragItemProvider()
                provider.registerItem(workspace.id, type: .acroSidebarWorkspace)
                provider.onEnd = { Task { @MainActor in model.endWorkspaceDrag(payload) } }
                return provider
            },
            acceptDrop: { edge in
                guard let payload = model.draggingWorkspace,
                      payload.serverId == entry.id,
                      let container = workspaceContainer(for: section, entry: entry)
                else { return false }
                return SidebarWorkspaceDropPlanner.insertionIndex(
                    draggedWorkspaceId: payload.workspaceId,
                    targetWorkspaceId: workspace.id,
                    orderedWorkspaceIds: container.map(\.id),
                    edge: edge
                ) != nil
            },
            performDrop: { edge in
                guard let payload = model.draggingWorkspace,
                      payload.serverId == entry.id,
                      let container = workspaceContainer(for: section, entry: entry),
                      let index = SidebarWorkspaceDropPlanner.insertionIndex(
                          draggedWorkspaceId: payload.workspaceId,
                          targetWorkspaceId: workspace.id,
                          orderedWorkspaceIds: container.map(\.id),
                          edge: edge
                      )
                else { return false }
                model.draggingWorkspace = nil
                model.requestReorderWorkspace(
                    payload.workspaceId, toGroup: section.groupId,
                    index: index, on: entry.connection)
                return true
            }
        )
        .id(scopedId)
    }

    private func workspaceContainer(
        for section: CompactSidebarSection, entry: RuntimeHub.Entry
    ) -> [Workspace]? {
        guard let groupId = section.groupId else {
            return model.ungroupedWorkspaces(on: entry.connection)
        }
        guard let group = entry.connection.workspaceGroups.first(where: { $0.id == groupId })
        else { return nil }
        return model.workspaces(in: group, on: entry.connection)
    }

    private func beginServerDrag(_ entry: RuntimeHub.Entry) -> NSItemProvider {
        model.draggingWorkspace = nil
        let payload = ServerDragPayload(serverId: entry.id)
        model.draggingServer = payload
        let provider = SidebarDragItemProvider()
        provider.registerItem(entry.id, type: .acroSidebarServer)
        provider.onEnd = { Task { @MainActor in model.endServerDrag(payload) } }
        return provider
    }

    private func serverInsertionIndex(
        target: RuntimeHub.Entry, edge: SidebarWorkspaceDropEdge
    ) -> Int? {
        guard let payload = model.draggingServer else { return nil }
        let remoteIds = SidebarServerProjection.entries(hub.entries)
            .filter { !$0.server.isLocal }
            .map(\.id)
        if target.server.isLocal {
            return edge == .bottom && remoteIds.first != payload.serverId ? 0 : nil
        }
        return SidebarWorkspaceDropPlanner.insertionIndex(
            draggedWorkspaceId: payload.serverId,
            targetWorkspaceId: target.id,
            orderedWorkspaceIds: remoteIds,
            edge: edge
        )
    }

    private func performServerDrop(
        target: RuntimeHub.Entry, edge: SidebarWorkspaceDropEdge
    ) -> Bool {
        guard let payload = model.draggingServer,
              let index = serverInsertionIndex(target: target, edge: edge)
        else { return false }
        model.draggingServer = nil
        do {
            try ServerDirectory.reorderRemote(payload.serverId, to: index, hub: hub)
            return true
        } catch {
            model.errorMessage = error.localizedDescription
            return false
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Button {
                model.requestCreateWorkspace()
            } label: {
                Image(systemName: "square.stack.3d.up.badge.plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .disabled(!model.runtime.connected)
            .help("在当前服务器新建工作区")
            .accessibilityLabel("新建工作区")

            Button {
                connectSheetPresented = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .help("连接服务器")
            .accessibilityLabel("连接服务器")

            Button {
                model.requestOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(SidebarFooterIconButtonStyle())
            .help("打开设置")
            .accessibilityLabel("设置")

            SidebarPresentationMenuButton(model: model)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

struct CompactSidebarServerSnapshot: Equatable {
    let id: String
    let name: String
    let initial: String
    let isLocal: Bool
    let isSelected: Bool
    let state: RuntimeConnection.ConnectionState
}

private struct CompactSidebarServerButton: View {
    let snapshot: CompactSidebarServerSnapshot
    let color: Color
    let select: () -> Void
    let createWorkspace: () -> Void
    let useWideSidebar: () -> Void
    let beginDrag: (() -> NSItemProvider)?
    let acceptDrop: (SidebarWorkspaceDropEdge) -> Bool
    let performDrop: (SidebarWorkspaceDropEdge) -> Bool
    @State private var dropEdge: SidebarWorkspaceDropEdge?

    var body: some View {
        Group {
            if let beginDrag {
                button.onDrag(beginDrag)
            } else {
                button
            }
        }
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            if dropEdge != nil {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 2)
            }
        }
        .onDrop(
            of: [.acroSidebarServer],
            delegate: SidebarWorkspaceRowDropDelegate(
                edge: Binding(get: { dropEdge }, set: { dropEdge = $0 }),
                height: CompactSidebarLayout.itemHeight,
                canAccept: acceptDrop,
                perform: performDrop
            )
        )
    }

    private var button: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.22))
                if snapshot.isLocal {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(snapshot.initial)
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .frame(
                width: CompactSidebarLayout.serverIconSize,
                height: CompactSidebarLayout.serverIconSize
            )
            .overlay(alignment: .topTrailing) {
                statusIndicator
                    .frame(width: 6, height: 6)
                    .padding(1.5)
                    .background(.bar, in: Circle())
                    .offset(x: 2, y: -2)
            }
        }
        .buttonStyle(CompactSidebarItemButtonStyle(selected: false))
        .help("\(snapshot.name)\n\(statusLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.name)
        .accessibilityValue(statusLabel)
        .accessibilityAddTraits(snapshot.isSelected ? [.isSelected] : [])
        .contextMenu {
            Button("新建工作区", action: createWorkspace)
                .disabled(snapshot.state != .connected)
            Divider()
            Button("使用完整侧边栏", action: useWideSidebar)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch snapshot.state {
        case .connected:
            Circle().fill(Color.green)
        case .connecting:
            ZStack {
                Circle().stroke(Color.orange, lineWidth: 1.5)
                Circle().fill(Color.orange).frame(width: 2.5, height: 2.5)
            }
        case .disconnected:
            Circle().stroke(Color.secondary, lineWidth: 1.5)
        }
    }

    private var statusLabel: String {
        switch snapshot.state {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnected: "未连接"
        }
    }
}

struct CompactSidebarWorkspaceSnapshot: Equatable {
    let id: String
    let name: String
    let initial: String
    let serverName: String
    let groupName: String?
    let sessionCount: Int
    let isSelected: Bool
    let canCreateTerminal: Bool
    let shortcutHint: String?
}

private struct CompactSidebarWorkspaceButton: View {
    let snapshot: CompactSidebarWorkspaceSnapshot
    let select: () -> Void
    let newTerminal: () -> Void
    let showInWideSidebar: () -> Void
    let beginDrag: () -> NSItemProvider
    let acceptDrop: (SidebarWorkspaceDropEdge) -> Bool
    let performDrop: (SidebarWorkspaceDropEdge) -> Bool
    @State private var dropEdge: SidebarWorkspaceDropEdge?

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Text(snapshot.initial)
                    .font(.system(size: 12, weight: .bold))
            }
            .frame(
                width: CompactSidebarLayout.workspaceIconSize,
                height: CompactSidebarLayout.workspaceIconSize
            )
            .overlay(alignment: .bottomTrailing) {
                if snapshot.sessionCount > 0 {
                    Text(snapshot.sessionCount > 99 ? "99+" : "\(snapshot.sessionCount)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(.bar, in: Capsule())
                        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(CompactSidebarItemButtonStyle(selected: snapshot.isSelected))
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            if dropEdge != nil {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hint = snapshot.shortcutHint {
                ShortcutHintPill(text: hint, fontSize: 8)
                    .offset(x: 2, y: -2)
                    .transition(.opacity)
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(snapshot.isSelected ? [.isSelected] : [])
        .contextMenu {
            Button("新建终端", action: newTerminal)
                .disabled(!snapshot.canCreateTerminal)
            Divider()
            Button("在完整侧边栏中显示", action: showInWideSidebar)
        }
        .onDrag(beginDrag)
        .onDrop(
            of: [.acroSidebarWorkspace],
            delegate: SidebarWorkspaceRowDropDelegate(
                edge: Binding(get: { dropEdge }, set: { dropEdge = $0 }),
                height: CompactSidebarLayout.itemHeight,
                canAccept: acceptDrop,
                perform: performDrop
            )
        )
    }

    private var helpText: String {
        let location = [snapshot.serverName, snapshot.groupName, snapshot.name]
            .compactMap { $0 }
            .joined(separator: " / ")
        return "\(location)\n\(snapshot.sessionCount) 个活跃会话"
    }

    private var accessibilityValue: String {
        let location = [snapshot.serverName, snapshot.groupName]
            .compactMap { $0 }
            .joined(separator: " / ")
        return "\(location)，\(snapshot.sessionCount) 个活跃会话"
    }
}

private struct CompactSidebarItemButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, selected: selected)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(
                    width: CompactSidebarLayout.itemWidth,
                    height: CompactSidebarLayout.itemHeight
                )
                .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.10), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var background: Color {
            if selected { return Color.accentColor.opacity(0.16) }
            if configuration.isPressed { return Color.primary.opacity(0.16) }
            return hovered ? Color.primary.opacity(0.08) : .clear
        }
    }
}
