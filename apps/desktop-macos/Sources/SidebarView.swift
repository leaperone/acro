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

struct SidebarRemovableProject: Equatable {
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
    let hasProjects: Bool
    let isInGroup: Bool
    let shortcutHint: String?
    let moveTargets: [SidebarMoveTarget]
    let removableProjects: [SidebarRemovableProject]
}

struct WorkspaceRowActions {
    let select: () -> Void
    let toggleExpand: () -> Void
    let newTerminal: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let moveToGroup: (String?) -> Void
    let removeProject: (String) -> Void
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
    let hasProject: Bool
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
                    Text(snapshot.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
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
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.name)

            if snapshot.hasProjects {
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
            if !snapshot.removableProjects.isEmpty {
                Menu("移除项目") {
                    ForEach(snapshot.removableProjects, id: \.id) { project in
                        Button(project.name, role: .destructive) {
                            actions.removeProject(project.id)
                        }
                        .disabled(project.disabled)
                    }
                }
            }
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
            if !snapshot.removableProjects.isEmpty || !snapshot.moveTargets.isEmpty {
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
            if snapshot.hasProject {
                Button("在同一项目新建终端", action: actions.newSibling)
                Divider()
            }
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
            Text("工作区")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
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
        .padding(.leading, 76) // 红绿灯让位(紧凑模式无标题栏)
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
        if runtime.workspaceGroups.isEmpty && runtime.workspaces.isEmpty {
            Button {
                Task { await model.createWorkspace() }
            } label: {
                Label("新建工作区", systemImage: "square.stack.3d.up.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else {
            ForEach(runtime.workspaceGroups) { group in
                groupSection(group)
            }
            let ungrouped = model.ungroupedWorkspaces
            if !ungrouped.isEmpty {
                if !runtime.workspaceGroups.isEmpty {
                    Text("未分组")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                ForEach(ungrouped) { workspace in
                    workspaceSection(workspace, group: nil, indent: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: WorkspaceGroup) -> some View {
        let expanded = model.expandedWorkspaceGroupIds.contains(group.id)
        let groupWorkspaces = model.workspaces(in: group)
        WorkspaceGroupRow(
            snapshot: WorkspaceGroupRowSnapshot(
                id: group.id,
                name: group.name,
                workspaceCount: groupWorkspaces.count,
                isExpanded: expanded
            ),
            actions: WorkspaceGroupRowActions(
                toggle: { model.toggleWorkspaceGroup(group.id) },
                createWorkspace: { Task { await model.createWorkspace(in: group.id) } },
                rename: { model.presentWorkspaceGroupEditor(workspaceGroupId: group.id, name: group.name) },
                dissolve: { model.pendingWorkspaceGroupRemoval = group },
                acceptWorkspaceDrop: { model.draggingWorkspaceId != nil },
                performWorkspaceDrop: {
                    guard let dragId = model.draggingWorkspaceId else { return false }
                    model.draggingWorkspaceId = nil
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
                    workspaceSection(workspace, group: group, indent: 14)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceSection(
        _ workspace: Workspace,
        group: WorkspaceGroup?,
        indent: CGFloat
    ) -> some View {
        let expanded = model.expandedWorkspaceIds.contains(workspace.id)
        let workspaceProjects = model.projects(in: workspace)
        let workspaceSessions = model.sessions(in: workspace)
        let currentGroup = model.workspaceGroup(containing: workspace.id)
        WorkspaceRow(
            snapshot: WorkspaceRowSnapshot(
                id: workspace.id,
                name: workspace.name,
                isSelected: model.selectedWorkspaceId == workspace.id
                    && (model.sidebarViewMode == .workspaces || model.selectedSessionId == nil),
                sessionCount: workspaceSessions.count,
                showsChevron: model.sidebarViewMode == .sessions,
                isExpanded: expanded,
                hasProjects: !workspaceProjects.isEmpty,
                isInGroup: currentGroup != nil,
                shortcutHint: model.cmdHeld
                    ? model.workspaceShortcutDigit(workspace.id).map { "⌘\($0)" }
                    : nil,
                moveTargets: runtime.workspaceGroups.map {
                    SidebarMoveTarget(id: $0.id, name: $0.name, disabled: $0.id == currentGroup?.id)
                },
                removableProjects: workspaceProjects.map { project in
                    SidebarRemovableProject(
                        id: project.id,
                        name: project.name,
                        disabled: workspaceSessions.contains { $0.projectId == project.id }
                    )
                }
            ),
            actions: WorkspaceRowActions(
                select: { model.selectWorkspace(workspace) },
                toggleExpand: { model.toggleWorkspace(workspace.id) },
                newTerminal: { model.requestNewTerminal(in: workspace) },
                rename: { model.presentWorkspaceRename(workspaceId: workspace.id, name: workspace.name) },
                delete: { model.pendingWorkspaceDeletion = workspace },
                moveToGroup: { groupId in
                    let target = runtime.workspaceGroups.first { $0.id == groupId }
                    Task { await model.moveWorkspace(workspace, to: target) }
                },
                removeProject: { projectId in
                    guard let project = workspaceProjects.first(where: { $0.id == projectId }) else { return }
                    Task { await model.removeProject(project, from: workspace) }
                },
                beginDrag: {
                    model.draggingWorkspaceId = workspace.id
                    return NSItemProvider(object: workspace.id as NSString)
                },
                acceptDrop: {
                    model.draggingWorkspaceId != nil && model.draggingWorkspaceId != workspace.id
                },
                performDrop: {
                    guard let dragId = model.draggingWorkspaceId else { return false }
                    model.draggingWorkspaceId = nil
                    // 落点 = 目标行之前;index 按"移除自己之后"的容器序列计算
                    let container = group.map(model.workspaces(in:)) ?? model.ungroupedWorkspaces
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
            if workspaceProjects.isEmpty {
                Button {
                    model.selectedWorkspaceId = workspace.id
                    model.presentProjectPicker(for: workspace)
                } label: {
                    Label("添加项目", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, indent + 22)
            } else {
                ForEach(workspaceSessions) { session in
                    SessionRow(
                        snapshot: SessionRowSnapshot(
                            id: session.id,
                            title: model.sessionDisplayName(session),
                            cwd: session.cwd,
                            alive: session.alive,
                            isSelected: model.selectedSessionId == session.id,
                            hasProject: model.project(for: session) != nil
                        ),
                        actions: SessionRowActions(
                            show: { model.showSession(session) },
                            newSibling: {
                                guard let project = model.project(for: session) else { return }
                                Task { _ = await model.openTerminal(project: project, workspace: workspace) }
                            },
                            terminate: { model.pendingSessionTermination = session }
                        )
                    )
                    .equatable()
                    .padding(.leading, indent + 16)
                }
                if workspaceSessions.isEmpty {
                    Button {
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
}
