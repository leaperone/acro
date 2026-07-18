// 工作台状态与动作。视图层保持薄;所有选择、布局、对话框与 RPC 动作集中在这里。
// 结构对应 cmux 的 TabManager/Workspace 聚合根思路(GPL-3.0-or-later,
// Copyright (c) 2024-present Manaflow, Inc.),按 acro 的远程 Runtime 模型精简重写。

import AppKit
import SwiftUI

enum SidebarViewMode: String, CaseIterable, Identifiable {
    case workspaces
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaces: "工作区"
        case .sessions: "会话"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "square.stack.3d.up"
        case .sessions: "terminal"
        }
    }
}

@MainActor
final class WorkbenchModel: ObservableObject {
    let runtime: RuntimeConnection

    // ---- 选择与布局 ----
    @Published var selectedWorkspaceId: String? { didSet { persistLayout() } }
    @Published var selectedProjectId: String?
    @Published var selectedSessionId: String?
    @Published var workspaceLayouts: [String: WorkspaceTerminalLayout] = [:] { didSet { persistLayout() } }
    @Published var expandedWorkspaceGroupIds: Set<String> = []
    @Published var expandedWorkspaceIds: Set<String> = []
    @Published var leftSidebarVisible = true { didSet { persistLayout() } }
    @Published var inspectorVisible = true { didSet { persistLayout() } }
    @Published var sidebarViewMode: SidebarViewMode {
        didSet { UserDefaults.standard.set(sidebarViewMode.rawValue, forKey: Self.sidebarModeKey) }
    }

    // ---- 终端焦点与注意力闪环 ----
    @Published private(set) var terminalFocusRequest = 0
    @Published private(set) var flashSessionId: String?
    @Published private(set) var flashToken = 0

    // ---- 对话框与浮层 ----
    @Published var showingCommandPalette = false
    @Published var showingWorkspaceGroupEditor = false
    @Published var editingWorkspaceGroupId: String?
    @Published var workspaceGroupName = ""
    @Published var showingWorkspaceEditor = false
    @Published var editingWorkspaceId: String?
    @Published var workspaceName = ""
    @Published var pendingWorkspaceDeletion: Workspace?
    @Published var pendingWorkspaceGroupRemoval: WorkspaceGroup?
    @Published var pendingSessionTermination: Session?
    @Published var projectPickerWorkspace: Workspace?
    @Published var terminalProjectPickerWorkspace: Workspace?
    @Published var errorMessage: String?

    // ---- 项目目录选择器 ----
    @Published var projectQuery = ""
    @Published var projectPathInput = "~"
    @Published var projectPathPreview = ""
    @Published var projectDirectoryPath = ""
    @Published var projectDirectoryParent: String?
    @Published var projectDirectoryHome = ""
    @Published var projectDirectoryEntries: [DirectoryEntry] = []
    @Published var projectPickerLoading = false

    private var layoutRestored = false
    private var workspaceGroupsInitialized = false
    private var workspaceExpansionInitialized = false
    private static let layoutKey = "acro.desktop.workbench.layout.v1"
    private static let sidebarModeKey = "acro.desktop.sidebar.view-mode"

    init(runtime: RuntimeConnection) {
        self.runtime = runtime
        sidebarViewMode = UserDefaults.standard.string(forKey: Self.sidebarModeKey)
            .flatMap(SidebarViewMode.init(rawValue:)) ?? .workspaces
    }

    // ---- 派生数据(全部走 codegen 类型) ----

    var activeSessions: [Session] {
        let workspaceSessionIds = Set(runtime.workspaces.flatMap(\.sessionIds))
        return runtime.sessions.filter { $0.alive && workspaceSessionIds.contains($0.id) }
    }

    var currentWorkspaceSessions: [Session] {
        selectedWorkspace.map(sessions(in:)) ?? []
    }

    var currentLayout: WorkspaceTerminalLayout? {
        selectedWorkspaceId.flatMap { workspaceLayouts[$0] }
    }

    var selectedWorkspace: Workspace? {
        runtime.workspaces.first { $0.id == selectedWorkspaceId }
    }

    var selectedProject: Project? {
        guard let selectedProjectId,
              let selectedWorkspace,
              selectedWorkspace.projectIds.contains(selectedProjectId)
        else { return nil }
        return runtime.projects.first { $0.id == selectedProjectId }
    }

    var selectedSession: Session? {
        activeSessions.first { $0.id == selectedSessionId }
    }

    var windowTitle: String {
        selectedProject?.name ?? selectedWorkspace?.name ?? "Acro"
    }

    var ungroupedWorkspaces: [Workspace] {
        let groupedIds = Set(runtime.workspaceGroups.flatMap(\.workspaceIds))
        return runtime.workspaces.filter { !groupedIds.contains($0.id) }
    }

    func workspaces(in group: WorkspaceGroup) -> [Workspace] {
        group.workspaceIds.compactMap { id in runtime.workspaces.first { $0.id == id } }
    }

    func workspaceGroup(containing workspaceId: String) -> WorkspaceGroup? {
        runtime.workspaceGroups.first { $0.workspaceIds.contains(workspaceId) }
    }

    func projects(in workspace: Workspace) -> [Project] {
        workspace.projectIds.compactMap { id in runtime.projects.first { $0.id == id } }
    }

    func sessions(in workspace: Workspace) -> [Session] {
        let sessionIds = Set(workspace.sessionIds)
        return runtime.sessions
            .filter { $0.alive && sessionIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func activeSessionCount(in workspace: Workspace) -> Int {
        let sessionIds = Set(workspace.sessionIds)
        return activeSessions.count { sessionIds.contains($0.id) }
    }

    func project(for session: Session) -> Project? {
        runtime.projects.first { $0.id == session.projectId }
    }

    func workspace(containing sessionId: String) -> Workspace? {
        runtime.workspaces.first { $0.sessionIds.contains(sessionId) }
    }

    func sessionDisplayName(_ session: Session) -> String {
        let projectName = project(for: session)?.name ?? "终端"
        guard let workspace = workspace(containing: session.id) else { return projectName }
        let related = sessions(in: workspace).filter { $0.projectId == session.projectId }
        guard related.count > 1, let index = related.firstIndex(where: { $0.id == session.id })
        else { return projectName }
        return "\(projectName) · \(index + 1)"
    }

    // ---- 焦点与导航 ----

    func requestTerminalFocus() {
        guard selectedSessionId != nil else { return }
        terminalFocusRequest &+= 1
    }

    private func flashPane(_ sessionId: String) {
        flashSessionId = sessionId
        flashToken &+= 1
    }

    func showSession(_ session: Session, flash: Bool = true) {
        guard let workspace = workspace(containing: session.id) else { return }
        selectedWorkspaceId = workspace.id
        selectedProjectId = session.projectId
        selectedSessionId = session.id
        var layout = workspaceLayouts[workspace.id] ?? WorkspaceTerminalLayout()
        if layout.root?.contains(session.id) == true {
            layout.focusedSessionId = session.id
        } else if let focusedSessionId = layout.focusedSessionId, layout.root != nil {
            layout.root = layout.root?.replacing(focusedSessionId, with: session.id)
            layout.focusedSessionId = session.id
        } else {
            layout = WorkspaceTerminalLayout(root: .leaf(session.id), focusedSessionId: session.id)
        }
        workspaceLayouts[workspace.id] = layout
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if flash { flashPane(session.id) }
        requestTerminalFocus()
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if let sessionId = workspaceLayouts[workspace.id]?.focusedSessionId,
           let session = sessions(in: workspace).first(where: { $0.id == sessionId }) {
            showSession(session)
        } else if let session = sessions(in: workspace).first {
            showSession(session)
        } else {
            selectedProjectId = nil
            selectedSessionId = nil
            workspaceLayouts[workspace.id] = WorkspaceTerminalLayout()
        }
    }

    func focusSession(_ session: Session, flash: Bool = false) {
        guard let workspace = workspace(containing: session.id) else { return }
        if selectedWorkspaceId != workspace.id { selectedWorkspaceId = workspace.id }
        if selectedProjectId != session.projectId { selectedProjectId = session.projectId }
        if selectedSessionId != session.id { selectedSessionId = session.id }
        var layout = workspaceLayouts[workspace.id] ?? WorkspaceTerminalLayout(root: .leaf(session.id))
        if layout.focusedSessionId != session.id {
            layout.focusedSessionId = session.id
            workspaceLayouts[workspace.id] = layout
        }
        expandedWorkspaceIds.insert(workspace.id)
        expandGroupContaining(workspace.id)
        if flash { flashPane(session.id) }
    }

    func focusSessionId(_ sessionId: String) {
        guard let session = activeSessions.first(where: { $0.id == sessionId }) else { return }
        focusSession(session)
    }

    func focusAdjacentPane(offset: Int) {
        guard let ids = currentLayout?.root?.sessionIds, ids.count > 1 else { return }
        let currentIndex = ids.firstIndex(of: currentLayout?.focusedSessionId ?? "") ?? 0
        let index = (currentIndex + offset + ids.count) % ids.count
        guard let session = activeSessions.first(where: { $0.id == ids[index] }) else { return }
        focusSession(session, flash: true)
        requestTerminalFocus()
    }

    func selectAdjacentSession(offset: Int) {
        let sessions = currentWorkspaceSessions
        guard !sessions.isEmpty else { return }
        let currentIndex = sessions.firstIndex { $0.id == selectedSessionId }
            ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        showSession(sessions[nextIndex])
    }

    func selectSession(at index: Int) {
        guard currentWorkspaceSessions.indices.contains(index) else { return }
        showSession(currentWorkspaceSessions[index])
    }

    func toggleWorkspaceGroup(_ workspaceGroupId: String) {
        if expandedWorkspaceGroupIds.contains(workspaceGroupId) {
            expandedWorkspaceGroupIds.remove(workspaceGroupId)
        } else {
            expandedWorkspaceGroupIds.insert(workspaceGroupId)
        }
    }

    func toggleWorkspace(_ workspaceId: String) {
        if expandedWorkspaceIds.contains(workspaceId) {
            expandedWorkspaceIds.remove(workspaceId)
        } else {
            expandedWorkspaceIds.insert(workspaceId)
        }
    }

    private func expandGroupContaining(_ workspaceId: String) {
        guard let group = workspaceGroup(containing: workspaceId) else { return }
        expandedWorkspaceGroupIds.insert(group.id)
    }

    // ---- 终端动作 ----

    func requestNewTerminal(in workspace: Workspace) {
        let workspaceProjects = projects(in: workspace)
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        switch workspaceProjects.count {
        case 0:
            presentProjectPicker(for: workspace)
        case 1:
            Task { _ = await openTerminal(project: workspaceProjects[0], workspace: workspace) }
        default:
            terminalProjectPickerWorkspace = workspace
            projectQuery = ""
        }
    }

    @discardableResult
    func openTerminal(project: Project, workspace: Workspace, activate: Bool = true) async -> Session? {
        do {
            let session = try await runtime.rpc("session.create", [
                "workspaceId": workspace.id,
                "projectId": project.id,
                "cols": 140,
                "rows": 40,
            ], as: Session.self)
            await runtime.refresh()
            if activate { showSession(session) }
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func splitTerminal(_ direction: TerminalSplitDirection) {
        guard let sourceSessionId = selectedSessionId,
              let selectedWorkspace,
              let selectedProject
        else { return }
        Task {
            guard let session = await openTerminal(
                project: selectedProject,
                workspace: selectedWorkspace,
                activate: false
            ) else { return }
            guard var layout = workspaceLayouts[selectedWorkspace.id],
                  layout.root?.contains(sourceSessionId) == true
            else { return }
            layout.root = layout.root?.splitting(
                sourceSessionId,
                direction: direction,
                newSessionId: session.id
            )
            layout.focusedSessionId = session.id
            workspaceLayouts[selectedWorkspace.id] = layout
            if selectedWorkspaceId == selectedWorkspace.id {
                focusSession(session, flash: true)
                requestTerminalFocus()
            }
        }
    }

    func closeFocusedPane() {
        guard let workspaceId = selectedWorkspaceId,
              let sessionId = currentLayout?.focusedSessionId
        else { return }
        closePane(workspaceId: workspaceId, sessionId: sessionId)
    }

    func closePane(workspaceId: String, sessionId: String) {
        guard var layout = workspaceLayouts[workspaceId] else { return }
        layout.remove(sessionId)
        workspaceLayouts[workspaceId] = layout
        guard selectedWorkspaceId == workspaceId else { return }
        guard let focusedSessionId = layout.focusedSessionId,
              let session = activeSessions.first(where: { $0.id == focusedSessionId })
        else {
            selectedSessionId = nil
            selectedProjectId = nil
            return
        }
        guard selectedSessionId != focusedSessionId else { return }
        focusSession(session)
        requestTerminalFocus()
    }

    func terminateSession(_ session: Session) async {
        do {
            let workspaceId = workspace(containing: session.id)?.id
            _ = try await runtime.rpc("session.kill", ["sessionId": session.id])
            pendingSessionTermination = nil
            await runtime.refresh()
            if let workspaceId, var layout = workspaceLayouts[workspaceId] {
                layout.remove(session.id)
                workspaceLayouts[workspaceId] = layout
                if selectedWorkspaceId == workspaceId {
                    if let focusedSessionId = layout.focusedSessionId,
                       let focusedSession = activeSessions.first(where: { $0.id == focusedSessionId }) {
                        focusSession(focusedSession)
                        requestTerminalFocus()
                    } else {
                        selectedSessionId = nil
                        selectedProjectId = nil
                    }
                }
            }
        } catch {
            pendingSessionTermination = nil
            errorMessage = error.localizedDescription
        }
    }

    // ---- 工作区与分组动作 ----

    func presentWorkspaceGroupEditor(workspaceGroupId: String?, name: String) {
        editingWorkspaceGroupId = workspaceGroupId
        workspaceGroupName = name
        showingWorkspaceGroupEditor = true
    }

    func presentWorkspaceRename(workspaceId: String, name: String) {
        editingWorkspaceId = workspaceId
        workspaceName = name
        showingWorkspaceEditor = true
    }

    func saveWorkspaceGroup() async {
        do {
            let name = workspaceGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingWorkspaceGroupId {
                _ = try await runtime.rpc("workspaceGroup.update", [
                    "workspaceGroupId": editingWorkspaceGroupId,
                    "name": name,
                ])
            } else {
                let group = try await runtime.rpc(
                    "workspaceGroup.create", ["name": name], as: WorkspaceGroup.self
                )
                expandedWorkspaceGroupIds.insert(group.id)
            }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createWorkspace(in workspaceGroupId: String? = nil) async {
        do {
            var params: [String: Any] = [:]
            if let workspaceGroupId { params["workspaceGroupId"] = workspaceGroupId }
            let workspace = try await runtime.rpc("workspace.create", params, as: Workspace.self)
            if let workspaceGroupId { expandedWorkspaceGroupIds.insert(workspaceGroupId) }
            expandedWorkspaceIds.insert(workspace.id)
            selectedWorkspaceId = workspace.id
            selectedProjectId = nil
            selectedSessionId = nil
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveWorkspaceName() async {
        guard let editingWorkspaceId else { return }
        do {
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": editingWorkspaceId,
                "name": workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async {
        do {
            _ = try await runtime.rpc("workspace.remove", ["workspaceId": workspace.id])
            workspaceLayouts.removeValue(forKey: workspace.id)
            expandedWorkspaceIds.remove(workspace.id)
            if selectedWorkspaceId == workspace.id {
                selectedWorkspaceId = nil
                selectedProjectId = nil
                selectedSessionId = nil
            }
            pendingWorkspaceDeletion = nil
            await runtime.refresh()
        } catch {
            pendingWorkspaceDeletion = nil
            errorMessage = error.localizedDescription
        }
    }

    func removeWorkspaceGroup(_ group: WorkspaceGroup) async {
        do {
            _ = try await runtime.rpc("workspaceGroup.remove", ["workspaceGroupId": group.id])
            expandedWorkspaceGroupIds.remove(group.id)
            pendingWorkspaceGroupRemoval = nil
            await runtime.refresh()
        } catch {
            pendingWorkspaceGroupRemoval = nil
            errorMessage = error.localizedDescription
        }
    }

    func moveWorkspace(_ workspace: Workspace, to group: WorkspaceGroup?) async {
        do {
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": workspace.id,
                "workspaceGroupId": group?.id ?? NSNull(),
            ])
            if let group { expandedWorkspaceGroupIds.insert(group.id) }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ---- 项目动作 ----

    func presentProjectPicker(for workspace: Workspace) {
        resetProjectPicker()
        projectPickerWorkspace = workspace
    }

    func resetProjectPicker() {
        projectPathInput = "~"
        projectPathPreview = ""
        projectDirectoryPath = ""
        projectDirectoryParent = nil
        projectDirectoryHome = ""
        projectDirectoryEntries = []
        projectPickerLoading = false
    }

    func loadProjectDirectory(_ requestedPath: String) async {
        guard projectPickerWorkspace != nil else { return }
        projectPickerLoading = true
        defer { projectPickerLoading = false }
        do {
            let listing = try await runtime.rpc(
                "filesystem.listDirectories",
                ["path": requestedPath],
                as: DirectoryListing.self
            )
            projectPathInput = listing.path
            projectPathPreview = listing.path
            projectDirectoryPath = listing.path
            projectDirectoryParent = listing.parent
            projectDirectoryHome = listing.home
            projectDirectoryEntries = listing.entries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func registerProjectAndOpenTerminal() async {
        guard let workspace = projectPickerWorkspace, !projectPathPreview.isEmpty else { return }
        projectPickerLoading = true
        do {
            let project = try await runtime.rpc(
                "project.register", ["path": projectPathPreview], as: Project.self
            )
            guard await addProject(project, to: workspace) else {
                projectPickerLoading = false
                return
            }
            projectPickerWorkspace = nil
            resetProjectPicker()
            _ = await openTerminal(project: project, workspace: workspace)
        } catch {
            projectPickerLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addProject(_ project: Project, to workspace: Workspace) async -> Bool {
        do {
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": workspace.id,
                "projectIds": workspace.projectIds + [project.id],
            ])
            selectedWorkspaceId = workspace.id
            selectedProjectId = project.id
            selectedSessionId = nil
            expandedWorkspaceIds.insert(workspace.id)
            await runtime.refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeProject(_ project: Project, from workspace: Workspace) async {
        do {
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": workspace.id,
                "projectIds": workspace.projectIds.filter { $0 != project.id },
            ])
            if selectedWorkspaceId == workspace.id, selectedProjectId == project.id {
                selectedProjectId = nil
                selectedSessionId = nil
            }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var filteredTerminalProjects: [Project] {
        guard let workspace = terminalProjectPickerWorkspace else { return [] }
        let values = projects(in: workspace)
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    // ---- 布局持久化与对账 ----

    func restoreLayoutIfNeeded() {
        guard !layoutRestored else { return }
        layoutRestored = true
        guard let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data)
        else { return }
        selectedWorkspaceId = snapshot.selectedWorkspaceId
        workspaceLayouts = snapshot.workspaceLayouts
        leftSidebarVisible = snapshot.leftSidebarVisible
        inspectorVisible = snapshot.inspectorVisible
    }

    var layoutWasRestored: Bool { layoutRestored }

    func reconcileLayoutState() {
        guard runtime.snapshotLoaded else { return }
        let validWorkspaceGroupIds = Set(runtime.workspaceGroups.map(\.id))
        if workspaceGroupsInitialized {
            expandedWorkspaceGroupIds.formIntersection(validWorkspaceGroupIds)
        } else {
            workspaceGroupsInitialized = true
            expandedWorkspaceGroupIds = validWorkspaceGroupIds
        }
        let validWorkspaceIds = Set(runtime.workspaces.map(\.id))
        expandedWorkspaceIds.formIntersection(validWorkspaceIds)
        let shouldInitializeWorkspaceExpansion = !workspaceExpansionInitialized
        workspaceExpansionInitialized = true
        workspaceLayouts = workspaceLayouts.filter { validWorkspaceIds.contains($0.key) }

        for workspace in runtime.workspaces {
            let workspaceSessions = sessions(in: workspace)
            let validSessionIds = Set(workspaceSessions.map(\.id))
            if var layout = workspaceLayouts[workspace.id] {
                layout.prune(validSessionIds: validSessionIds)
                workspaceLayouts[workspace.id] = layout
            } else if let firstSessionId = workspaceSessions.first?.id {
                workspaceLayouts[workspace.id] = WorkspaceTerminalLayout(
                    root: .leaf(firstSessionId),
                    focusedSessionId: firstSessionId
                )
            } else {
                workspaceLayouts[workspace.id] = WorkspaceTerminalLayout()
            }
        }

        if let selectedWorkspaceId, !validWorkspaceIds.contains(selectedWorkspaceId) {
            self.selectedWorkspaceId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = runtime.workspaces.first?.id
        }
        guard let selectedWorkspaceId else {
            selectedProjectId = nil
            selectedSessionId = nil
            return
        }
        if shouldInitializeWorkspaceExpansion {
            expandedWorkspaceIds.insert(selectedWorkspaceId)
            expandGroupContaining(selectedWorkspaceId)
        }
        guard let focusedSessionId = workspaceLayouts[selectedWorkspaceId]?.focusedSessionId,
              let focusedSession = activeSessions.first(where: { $0.id == focusedSessionId })
        else {
            selectedProjectId = nil
            selectedSessionId = nil
            return
        }
        selectedSessionId = focusedSessionId
        selectedProjectId = focusedSession.projectId
    }

    private func persistLayout() {
        guard layoutRestored else { return }
        let snapshot = WorkbenchLayoutSnapshot(
            selectedWorkspaceId: selectedWorkspaceId,
            workspaceLayouts: workspaceLayouts,
            leftSidebarVisible: leftSidebarVisible,
            inspectorVisible: inspectorVisible
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.layoutKey)
    }
}
