// 工作台状态与动作。视图层保持薄;所有选择、布局、对话框与 RPC 动作集中在这里。
// 结构对应 cmux 的 TabManager/Workspace 聚合根思路(GPL-3.0-or-later,
// Copyright (c) 2024-present Manaflow, Inc.),按 acro 的远程 Runtime 模型精简重写。
// 布局叶子是标签组窗格(Bonsplit 模型):标签、分屏、拖拽都在 WorkspaceTerminalLayout 上操作。

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

// 应用内拖拽的真源(cmux SidebarWorkspaceDragRegistry 模式):
// NSItemProvider 异步且跨进程,应用内直接读这里,同步且无歧义。
struct TabDragPayload: Equatable {
    let sessionId: String
    let sourcePaneId: String
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

    // 设置窗口打开请求(Commands 里 openWindow 不可用,经视图转发)
    @Published private(set) var settingsOpenRequest = 0

    func requestOpenSettings() {
        settingsOpenRequest &+= 1
    }

    // ---- 终端焦点与注意力闪环 ----
    @Published private(set) var terminalFocusRequest = 0
    @Published private(set) var flashSessionId: String?
    @Published private(set) var flashToken = 0

    // ---- 拖拽与快捷键提示 ----
    @Published var draggingTab: TabDragPayload?
    @Published var draggingWorkspaceId: String?
    @Published private(set) var cmdHeld = false

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
    private var flagsMonitor: Any?
    private static let layoutKey = "acro.desktop.workbench.layout.v2"
    private static let sidebarModeKey = "acro.desktop.sidebar.view-mode"

    init(runtime: RuntimeConnection) {
        self.runtime = runtime
        sidebarViewMode = UserDefaults.standard.string(forKey: Self.sidebarModeKey)
            .flatMap(SidebarViewMode.init(rawValue:)) ?? .workspaces
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == .command
            Task { @MainActor in
                if self?.cmdHeld != held { self?.cmdHeld = held }
            }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: .acroShortcutAction, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?["action"] as? String,
                  let action = ShortcutAction(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                self?.perform(action)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .acroSelectWorkspace, object: nil, queue: .main
        ) { [weak self] note in
            guard let index = note.userInfo?["index"] as? Int else { return }
            MainActor.assumeIsolated {
                self?.selectWorkspace(at: index)
            }
        }
    }

    // 快捷键与菜单的统一入口;无效时机的调用由各方法的 guard 空操作
    func perform(_ action: ShortcutAction) {
        switch action {
        case .newTerminalTab:
            if let workspace = selectedWorkspace { requestNewTerminal(in: workspace) }
        case .newWorkspace:
            Task { await createWorkspace() }
        case .newWorkspaceGroup:
            presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
        case .commandPalette:
            showingCommandPalette = true
        case .toggleSidebar:
            leftSidebarVisible.toggle()
        case .toggleInspector:
            inspectorVisible.toggle()
        case .splitRight:
            splitTerminal(.horizontal)
        case .splitDown:
            splitTerminal(.vertical)
        case .equalizeSplits:
            equalizeSplits()
        case .focusPaneLeft:
            focusPane(toward: .left)
        case .focusPaneDown:
            focusPane(toward: .down)
        case .focusPaneUp:
            focusPane(toward: .up)
        case .focusPaneRight:
            focusPane(toward: .right)
        case .closeTab:
            requestKillFocusedTab()
        case .previousTab:
            selectAdjacentTab(offset: -1)
        case .nextTab:
            selectAdjacentTab(offset: 1)
        case .focusTerminal:
            requestTerminalFocus()
        case .openSettings:
            requestOpenSettings()
        }
    }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
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

    // 侧边栏显示序 = ⌘数字序:分组内工作区在前,未分组在后
    var orderedWorkspaces: [Workspace] {
        runtime.workspaceGroups.flatMap(workspaces(in:)) + ungroupedWorkspaces
    }

    func workspaceShortcutDigit(_ workspaceId: String) -> Int? {
        guard let index = orderedWorkspaces.firstIndex(where: { $0.id == workspaceId }),
              index < 9
        else { return nil }
        return index + 1
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

    func session(_ sessionId: String) -> Session? {
        activeSessions.first { $0.id == sessionId }
    }

    func sessionDisplayName(_ session: Session) -> String {
        let projectName = project(for: session)?.name ?? "终端"
        guard let workspace = workspace(containing: session.id) else { return projectName }
        let related = sessions(in: workspace).filter { $0.projectId == session.projectId }
        guard related.count > 1, let index = related.firstIndex(where: { $0.id == session.id })
        else { return projectName }
        return "\(projectName) · \(index + 1)"
    }

    // ---- 布局变更入口(集中同步选中态与持久化) ----

    private func mutateCurrentLayout(_ transform: (inout WorkspaceTerminalLayout) -> Void) {
        guard let selectedWorkspaceId else { return }
        var layout = workspaceLayouts[selectedWorkspaceId] ?? WorkspaceTerminalLayout()
        transform(&layout)
        workspaceLayouts[selectedWorkspaceId] = layout
        syncSelectionFromLayout()
    }

    private func syncSelectionFromLayout() {
        guard let focusedSessionId = currentLayout?.focusedSessionId,
              let session = session(focusedSessionId)
        else {
            if currentLayout?.root == nil {
                selectedSessionId = nil
                selectedProjectId = nil
            }
            return
        }
        if selectedSessionId != session.id { selectedSessionId = session.id }
        if selectedProjectId != session.projectId { selectedProjectId = session.projectId }
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
        mutateCurrentLayout { $0.adopt(session.id) }
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if flash { flashPane(session.id) }
        requestTerminalFocus()
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if workspaceLayouts[workspace.id]?.root == nil,
           let session = sessions(in: workspace).first {
            mutateCurrentLayout { $0.adopt(session.id) }
        }
        syncSelectionFromLayout()
        if let focusedSessionId = currentLayout?.focusedSessionId {
            flashPane(focusedSessionId)
            requestTerminalFocus()
        }
    }

    func selectWorkspace(at index: Int) {
        let ordered = orderedWorkspaces
        guard ordered.indices.contains(index) else { return }
        selectWorkspace(ordered[index])
    }

    func focusSession(_ session: Session, flash: Bool = false) {
        guard let workspace = workspace(containing: session.id) else { return }
        if selectedWorkspaceId != workspace.id { selectedWorkspaceId = workspace.id }
        mutateCurrentLayout { $0.adopt(session.id) }
        expandedWorkspaceIds.insert(workspace.id)
        expandGroupContaining(workspace.id)
        if flash { flashPane(session.id) }
    }

    func focusSessionId(_ sessionId: String) {
        guard let session = session(sessionId) else { return }
        focusSession(session)
    }

    // ---- 标签动作 ----

    func selectTab(_ sessionId: String, inPane paneId: String) {
        mutateCurrentLayout { $0.selectTab(sessionId, inPane: paneId) }
        flashPane(sessionId)
        requestTerminalFocus()
    }

    // 布局层移除(surface 自行退出、会话已死时用);活会话的"关闭标签"走 requestKillTab
    func closeTab(_ sessionId: String) {
        mutateCurrentLayout { $0.removeTab(sessionId) }
        requestTerminalFocus()
    }

    // 关闭标签二次确认开关(设置窗口可关;cmux confirmQuit 同款思路)
    static let confirmCloseTabKey = "acro.confirm-close-tab"

    private var confirmCloseTab: Bool {
        UserDefaults.standard.object(forKey: Self.confirmCloseTabKey) == nil
            || UserDefaults.standard.bool(forKey: Self.confirmCloseTabKey)
    }

    // 关闭标签 = 真正终止终端;开着二次确认时先弹框,terminateSession 成功后把标签摘掉
    func requestKillTab(_ sessionId: String) {
        guard let session = session(sessionId) else {
            closeTab(sessionId)
            return
        }
        if confirmCloseTab {
            pendingSessionTermination = session
        } else {
            Task { await terminateSession(session) }
        }
    }

    func requestKillFocusedTab() {
        guard let sessionId = currentLayout?.focusedSessionId else { return }
        requestKillTab(sessionId)
    }

    func selectAdjacentTab(offset: Int) {
        guard let pane = currentLayout?.focusedPane, pane.sessionIds.count > 1,
              let selected = pane.selectedSessionId,
              let index = pane.sessionIds.firstIndex(of: selected)
        else { return }
        let next = pane.sessionIds[(index + offset + pane.sessionIds.count) % pane.sessionIds.count]
        selectTab(next, inPane: pane.id)
    }

    func moveTab(_ payload: TabDragPayload, toPane paneId: String, at index: Int?) {
        mutateCurrentLayout { $0.moveTab(payload.sessionId, toPane: paneId, at: index) }
        flashPane(payload.sessionId)
        requestTerminalFocus()
    }

    func moveTabToSplit(
        _ payload: TabDragPayload,
        ofPane paneId: String,
        direction: TerminalSplitDirection,
        newPaneFirst: Bool
    ) {
        mutateCurrentLayout {
            $0.moveTabToSplit(
                payload.sessionId, ofPane: paneId, direction: direction, newPaneFirst: newPaneFirst
            )
        }
        flashPane(payload.sessionId)
        requestTerminalFocus()
    }

    func focusPane(_ paneId: String) {
        mutateCurrentLayout { layout in
            layout.focusedPaneId = paneId
        }
    }

    // 分隔线拖动;ratio 持久化在布局树里
    func setSplitRatio(_ splitId: UUID, ratio: Double) {
        mutateCurrentLayout { $0.setSplitRatio(splitId, ratio: ratio) }
    }

    // 均分窗格(CmuxPanes equalizeDividerPlan)
    func equalizeSplits() {
        mutateCurrentLayout { $0.equalizeSplits() }
        requestTerminalFocus()
    }

    // vim 方向导航:按窗格几何找目标(⌘⇧HJKL)
    func focusPane(toward direction: PaneDirection) {
        guard let targetPaneId = currentLayout?.paneId(toward: direction) else { return }
        mutateCurrentLayout { $0.focusedPaneId = targetPaneId }
        if let sessionId = currentLayout?.root?.pane(withId: targetPaneId)?.selectedSessionId {
            flashPane(sessionId)
        }
        requestTerminalFocus()
    }

    // ---- 终端动作 ----

    func requestNewTerminal(in workspace: Workspace, paneId: String? = nil) {
        let workspaceProjects = projects(in: workspace)
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if let paneId { mutateCurrentLayout { $0.focusedPaneId = paneId } }
        switch workspaceProjects.count {
        case 0:
            presentProjectPicker(for: workspace)
        case 1:
            Task { _ = await openTerminal(project: workspaceProjects[0], workspace: workspace) }
        default:
            // 有当前项目时新标签直接跟随当前项目(cmux newTab 语义),否则再弹选择器
            if let selectedProject {
                Task { _ = await openTerminal(project: selectedProject, workspace: workspace) }
            } else {
                terminalProjectPickerWorkspace = workspace
                projectQuery = ""
            }
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
        guard let sourcePaneId = currentLayout?.focusedPane?.id,
              let selectedWorkspace,
              let selectedProject
        else { return }
        Task {
            guard let session = await openTerminal(
                project: selectedProject,
                workspace: selectedWorkspace,
                activate: false
            ) else { return }
            guard selectedWorkspaceId == selectedWorkspace.id else { return }
            mutateCurrentLayout {
                $0.split(fromPane: sourcePaneId, direction: direction, newSessionId: session.id)
            }
            flashPane(session.id)
            requestTerminalFocus()
        }
    }

    func terminateSession(_ session: Session) async {
        do {
            let workspaceId = workspace(containing: session.id)?.id
            _ = try await runtime.rpc("session.kill", ["sessionId": session.id])
            pendingSessionTermination = nil
            await runtime.refresh()
            if let workspaceId, var layout = workspaceLayouts[workspaceId] {
                layout.removeTab(session.id)
                workspaceLayouts[workspaceId] = layout
                if selectedWorkspaceId == workspaceId {
                    syncSelectionFromLayout()
                    requestTerminalFocus()
                }
            }
        } catch {
            pendingSessionTermination = nil
            errorMessage = error.localizedDescription
        }
    }

    // ---- 工作区与分组动作 ----

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

    // 拖拽重排:workspaceGroupId 为 nil 表示未分组区
    func reorderWorkspace(_ workspaceId: String, toGroup workspaceGroupId: String?, index: Int) async {
        do {
            _ = try await runtime.rpc("workspace.reorder", [
                "workspaceId": workspaceId,
                "workspaceGroupId": workspaceGroupId ?? NSNull(),
                "index": index,
            ])
            if let workspaceGroupId { expandedWorkspaceGroupIds.insert(workspaceGroupId) }
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
                // 新出现的会话(其他客户端创建的)并入布局作后台标签,不抢当前选中
                for session in workspaceSessions
                where layout.root?.paneContaining(session.id) == nil {
                    if let pane = layout.focusedPane {
                        layout.root = layout.root?.updatingPane(pane.id) {
                            $0.appendTab(session.id, select: false)
                        }
                    } else {
                        layout.adopt(session.id)
                    }
                }
                workspaceLayouts[workspace.id] = layout
            } else if !workspaceSessions.isEmpty {
                // 首次见到该工作区:全部会话进同一窗格作标签
                let pane = PaneTabGroup(sessionIds: workspaceSessions.map(\.id))
                workspaceLayouts[workspace.id] = WorkspaceTerminalLayout(root: .pane(pane))
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
        guard selectedWorkspaceId != nil else {
            selectedProjectId = nil
            selectedSessionId = nil
            return
        }
        if shouldInitializeWorkspaceExpansion, let selectedWorkspaceId {
            expandedWorkspaceIds.insert(selectedWorkspaceId)
            expandGroupContaining(selectedWorkspaceId)
        }
        syncSelectionFromLayout()
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
