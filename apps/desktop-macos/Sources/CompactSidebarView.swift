// Compact 左侧栏：固定宽度的服务器 / 工作区快速切换轨道。
// 结构管理、会话树和破坏性操作保留在完整侧边栏。

import SwiftUI

enum CompactSidebarLayout {
    static let width: CGFloat = 64
    static let headerHeight: CGFloat = 38
    static let itemWidth: CGFloat = 52
    static let itemHeight: CGFloat = 44
    static let serverIconSize: CGFloat = 32
    static let workspaceIconSize: CGFloat = 36
}

enum CompactSidebarIdentity {
    static func initial(for name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.first.map { String($0).uppercased() } ?? "•"
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
                name: group.name,
                workspaces: values
            )
        }
        let groupedIds = Set(groups.flatMap(\.workspaceIds))
        let ungrouped = workspaces.filter { !groupedIds.contains($0.id) }
        if !ungrouped.isEmpty {
            sections.append(CompactSidebarSection(
                id: "ungrouped",
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    LazyVStack(spacing: 12) {
                        if hub.entries.isEmpty {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                                .frame(width: CompactSidebarLayout.itemWidth, height: 36)
                                .help("Runtime 尚未就绪")
                                .accessibilityLabel("Runtime 尚未就绪")
                        }
                        ForEach(hub.entries) { entry in
                            RuntimeConnectionScope(connection: entry.connection) { connection in
                                serverSection(entry)
                                    .onChange(of: connection.workspaces.map(\.id)) { _, _ in
                                        scrollToSelection(proxy)
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .onChange(of: selectedWorkspaceScrollId, initial: true) { _, _ in
                    scrollToSelection(proxy)
                }
                .onChange(of: workspaceIds) { _, _ in
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

    private var workspaceIds: [String] {
        hub.entries.flatMap { entry in
            entry.connection.workspaces.map {
                workspaceScrollId(serverId: entry.id, workspaceId: $0.id)
            }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selectedWorkspaceScrollId else { return }
        if reduceMotion {
            proxy.scrollTo(selectedWorkspaceScrollId, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(selectedWorkspaceScrollId, anchor: .center)
            }
        }
    }

    private func workspaceScrollId(serverId: String, workspaceId: String) -> String {
        "workspace:\(serverId):\(workspaceId)"
    }

    private func serverSection(_ entry: RuntimeHub.Entry) -> some View {
        let sections = CompactSidebarProjection.sections(
            groups: entry.connection.workspaceGroups,
            workspaces: entry.connection.workspaces
        )
        return VStack(spacing: 6) {
            CompactSidebarServerButton(
                snapshot: CompactSidebarServerSnapshot(
                    id: entry.id,
                    name: entry.server.name,
                    initial: CompactSidebarIdentity.initial(for: entry.server.name),
                    isLocal: entry.server.isLocal,
                    isSelected: model.selectedServerId == entry.id,
                    state: entry.connection.state
                ),
                color: Self.palette[CompactSidebarIdentity.colorIndex(for: entry.id)],
                select: { model.activate(serverId: entry.id) },
                createWorkspace: {
                    model.activate(serverId: entry.id)
                    model.requestCreateWorkspace()
                },
                useWideSidebar: { model.setLeftSidebarPresentation(.wide) }
            )
            .equatable()

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(spacing: 6) {
                    ForEach(section.workspaces) { workspace in
                        compactWorkspaceButton(
                            workspace,
                            groupName: section.name,
                            entry: entry
                        )
                    }
                }
                .padding(.top, index == 0 ? 0 : 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func compactWorkspaceButton(
        _ workspace: Workspace,
        groupName: String?,
        entry: RuntimeHub.Entry
    ) -> some View {
        let sessions = model.sessions(in: workspace, on: entry.connection)
        let scopedId = workspaceScrollId(serverId: entry.id, workspaceId: workspace.id)
        let colorIndex = CompactSidebarIdentity.colorIndex(for: scopedId)
        return CompactSidebarWorkspaceButton(
            snapshot: CompactSidebarWorkspaceSnapshot(
                id: scopedId,
                name: workspace.name,
                initial: CompactSidebarIdentity.initial(for: workspace.name),
                serverName: entry.server.name,
                groupName: groupName,
                sessionCount: sessions.count,
                isSelected: model.selectedServerId == entry.id
                    && model.selectedWorkspaceId == workspace.id,
                canCreateTerminal: entry.connection.connected
            ),
            color: Self.palette[colorIndex],
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
            }
        )
        .equatable()
        .id(scopedId)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Button {
                model.requestCreateWorkspace()
            } label: {
                Image(systemName: "plus")
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

private struct CompactSidebarServerButton: View, Equatable {
    let snapshot: CompactSidebarServerSnapshot
    let color: Color
    let select: () -> Void
    let createWorkspace: () -> Void
    let useWideSidebar: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(snapshot.isSelected ? 0.30 : 0.20))
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
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.bar, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
        .buttonStyle(CompactSidebarItemButtonStyle(selected: snapshot.isSelected))
        .help("\(snapshot.name)\n\(statusLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.name)
        .accessibilityValue(statusLabel)
        .contextMenu {
            Button("新建工作区", action: createWorkspace)
                .disabled(snapshot.state != .connected)
            Divider()
            Button("使用完整侧边栏", action: useWideSidebar)
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
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
}

private struct CompactSidebarWorkspaceButton: View, Equatable {
    let snapshot: CompactSidebarWorkspaceSnapshot
    let color: Color
    let select: () -> Void
    let newTerminal: () -> Void
    let showInWideSidebar: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(snapshot.isSelected ? 0.30 : 0.20))
                Text(snapshot.initial)
                    .font(.system(size: 14, weight: .bold))
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
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.name)
        .accessibilityValue("\(snapshot.serverName)，\(snapshot.sessionCount) 个活跃会话")
        .contextMenu {
            Button("新建终端", action: newTerminal)
                .disabled(!snapshot.canCreateTerminal)
            Divider()
            Button("在完整侧边栏中显示", action: showInWideSidebar)
        }
    }

    private var helpText: String {
        let location = [snapshot.serverName, snapshot.groupName, snapshot.name]
            .compactMap { $0 }
            .joined(separator: " / ")
        return "\(location)\n\(snapshot.sessionCount) 个活跃会话"
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
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 22)
                            .padding(.leading, 1)
                    }
                }
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
