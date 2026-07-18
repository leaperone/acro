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
    // 每次拖拽唯一:陈旧 provider 的延迟 deinit(外部 App 异步 loadItem 持有数秒)
    // 不会误清后来同一标签的新一轮拖拽
    let token = UUID()
}

@MainActor
final class WorkbenchModel: ObservableObject {
    // 多主机:hub 为每台已配对服务器维持一条常驻连接;
    // runtime 始终指向"当前查看的服务器"的连接,旧的单连接代码路径保持不变。
    let hub: RuntimeHub
    private let fallbackRuntime = RuntimeConnection()

    var runtime: RuntimeConnection {
        hub.connection(for: selectedServerId) ?? hub.entries.first?.connection ?? fallbackRuntime
    }

    // ---- 选择与布局 ----
    @Published var selectedServerId: String? { didSet { persistLayout() } }
    @Published var selectedWorkspaceId: String? { didSet { persistLayout() } }
    @Published var selectedSessionId: String?
    @Published var workspaceLayouts: [String: WorkspaceTerminalLayout] = [:] {
        didSet {
            persistLayout()
            scheduleLayoutSync()
        }
    }
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

    // ---- 布局多端同步状态(不入 @Published:纯簿记,不驱动 UI) ----
    // 已应用的服务端布局修订号;自己推送成功后也记这里,回声(rev 相同)不会覆盖本地
    private var appliedLayoutRevs: [String: Int] = [:]
    // 上次与服务端达成一致的规范化编码;编码相同 = 无需推送
    private var lastSyncedLayouts: [String: String] = [:]
    // 服务端布局本机解不开(schema 比本机新):冻结该工作区的推送,
    // 否则旧客户端每次启动都会把旧 schema 布局推回去,把新客户端打回原形
    private var layoutPushFrozen: Set<String> = []
    private var layoutSyncTask: Task<Void, Never>?

    // ---- 拖拽与快捷键提示 ----
    @Published var draggingTab: TabDragPayload?
    @Published var draggingWorkspaceId: String?
    // 工作区拖拽的来源服务器:禁止拖进另一台服务器的分组
    @Published var draggingWorkspaceServerId: String?
    @Published private(set) var cmdHeld = false

    // ---- 对话框与浮层 ----
    @Published var showingCommandPalette = false
    @Published var showingWorkspaceGroupEditor = false
    @Published var editingWorkspaceGroupId: String?
    @Published var workspaceGroupName = ""
    @Published var showingWorkspaceEditor = false
    @Published var editingWorkspaceId: String?
    @Published var workspaceName = ""
    @Published var pendingWorkspaceDeletion: Workspace? {
        didSet { if pendingWorkspaceDeletion != nil { pendingServerId = selectedServerId } }
    }
    @Published var pendingWorkspaceGroupRemoval: WorkspaceGroup? {
        didSet { if pendingWorkspaceGroupRemoval != nil { pendingServerId = selectedServerId } }
    }
    @Published var pendingSessionTermination: Session? {
        didSet { if pendingSessionTermination != nil { pendingServerId = selectedServerId } }
    }
    // 弹框/编辑器打开时的目标服务器:确认动作按它路由,
    // 避免弹框期间切换服务器把破坏性 RPC 发错目标
    private var pendingServerId: String?

    private var pendingRuntime: RuntimeConnection {
        hub.connection(for: pendingServerId) ?? runtime
    }
    @Published var errorMessage: String?

    // ---- 项目目录选择器 ----

    private var layoutRestored = false
    private var workspaceGroupsInitialized = false
    private var workspaceExpansionInitialized = false
    private var flagsMonitor: Any?
    private static let layoutKey = "acro.desktop.workbench.layout.v2"
    private static let sidebarModeKey = "acro.desktop.sidebar.view-mode"

    init(hub: RuntimeHub) {
        self.hub = hub
        selectedServerId = ClientConfig.load()?.activeServer?.id
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

    // 切换当前查看的服务器:其他服务器的连接与会话保持在线,只换视角
    func activate(serverId: String) {
        guard selectedServerId != serverId else { return }
        selectedServerId = serverId
        selectedWorkspaceId = nil
        selectedSessionId = nil
        reconcileLayoutState()
    }

    // ---- 派生数据(全部走 codegen 类型) ----

    var activeSessions: [Session] {
        let workspaceSessionIds = Set(runtime.workspaces.flatMap(\.sessionIds))
        return runtime.sessions.filter { $0.alive && workspaceSessionIds.contains($0.id) }
    }

    var currentWorkspaceSessions: [Session] {
        selectedWorkspace.map { sessions(in: $0) } ?? []
    }

    var currentLayout: WorkspaceTerminalLayout? {
        selectedWorkspaceId.flatMap { workspaceLayouts[$0] }
    }

    var selectedWorkspace: Workspace? {
        runtime.workspaces.first { $0.id == selectedWorkspaceId }
    }

    var selectedSession: Session? {
        activeSessions.first { $0.id == selectedSessionId }
    }

    var windowTitle: String {
        selectedWorkspace?.name ?? "Acro"
    }

    var ungroupedWorkspaces: [Workspace] {
        let groupedIds = Set(runtime.workspaceGroups.flatMap(\.workspaceIds))
        return runtime.workspaces.filter { !groupedIds.contains($0.id) }
    }

    // 侧边栏显示序 = ⌘数字序:分组内工作区在前,未分组在后
    var orderedWorkspaces: [Workspace] {
        runtime.workspaceGroups.flatMap { workspaces(in: $0) } + ungroupedWorkspaces
    }

    func workspaceShortcutDigit(_ workspaceId: String) -> Int? {
        guard let index = orderedWorkspaces.firstIndex(where: { $0.id == workspaceId }),
              index < 9
        else { return nil }
        return index + 1
    }

    func workspaces(in group: WorkspaceGroup, on connection: RuntimeConnection? = nil) -> [Workspace] {
        let source = connection ?? runtime
        return group.workspaceIds.compactMap { id in source.workspaces.first { $0.id == id } }
    }

    func ungroupedWorkspaces(on connection: RuntimeConnection) -> [Workspace] {
        let groupedIds = Set(connection.workspaceGroups.flatMap(\.workspaceIds))
        return connection.workspaces.filter { !groupedIds.contains($0.id) }
    }

    func workspaceGroup(containing workspaceId: String, on connection: RuntimeConnection? = nil) -> WorkspaceGroup? {
        (connection ?? runtime).workspaceGroups.first { $0.workspaceIds.contains(workspaceId) }
    }

    func sessions(in workspace: Workspace, on connection: RuntimeConnection? = nil) -> [Session] {
        let sessionIds = Set(workspace.sessionIds)
        return (connection ?? runtime).sessions
            .filter { $0.alive && sessionIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func activeSessionCount(in workspace: Workspace) -> Int {
        let sessionIds = Set(workspace.sessionIds)
        return activeSessions.count { sessionIds.contains($0.id) }
    }

    func workspace(containing sessionId: String) -> Workspace? {
        runtime.workspaces.first { $0.sessionIds.contains(sessionId) }
    }

    func session(_ sessionId: String) -> Session? {
        activeSessions.first { $0.id == sessionId }
    }

    func sessionDisplayName(_ session: Session, on connection: RuntimeConnection? = nil) -> String {
        let source = connection ?? runtime
        let base = Self.sessionTitle(session)
        guard let workspace = source.workspaces.first(where: { $0.sessionIds.contains(session.id) })
        else { return base }
        let related = sessions(in: workspace, on: source).filter { Self.sessionTitle($0) == base }
        guard related.count > 1, let index = related.firstIndex(where: { $0.id == session.id })
        else { return base }
        return "\(base) · \(index + 1)"
    }

    // 标题 = 工作目录尾段(既定事实的最短表达);根目录等退化为"终端"
    static func sessionTitle(_ session: Session) -> String {
        let last = (session.cwd as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "终端" : last
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
            }
            return
        }
        if selectedSessionId != session.id { selectedSessionId = session.id }
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

    // 拖拽负载有效性:会话必须仍在"当前布局"的来源窗格里。
    // 防两类脏 drop:拖拽中切了工作区(payload 指向别的布局树,落下会双挂 PTY);
    // 拖拽取消后残留的陈旧 payload(会话可能已被杀)。
    func validDrag(_ payload: TabDragPayload?) -> Bool {
        guard let payload,
              let source = currentLayout?.root?.pane(withId: payload.sourcePaneId),
              source.sessionIds.contains(payload.sessionId)
        else { return false }
        return true
    }

    // 拖拽会话结束(drop/取消/拖出窗口)后的兜底清理
    func endTabDrag(_ payload: TabDragPayload) {
        if draggingTab == payload { draggingTab = nil }
    }

    func moveTab(_ payload: TabDragPayload, toPane paneId: String, at index: Int?) {
        guard validDrag(payload) else { return }
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
        guard validDrag(payload) else { return }
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
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        expandedWorkspaceIds.insert(workspace.id)
        if let paneId { mutateCurrentLayout { $0.focusedPaneId = paneId } }
        Task { _ = await openTerminal(in: workspace) }
    }

    // 路径继承源:聚焦终端优先;fallback 工作区第一个存活终端;都没有交给服务端(家目录)
    private func inheritCwdSource(in workspace: Workspace) -> String? {
        if selectedWorkspaceId == workspace.id,
           let focused = currentLayout?.focusedSessionId,
           session(focused) != nil {
            return focused
        }
        return sessions(in: workspace).first?.id
    }

    @discardableResult
    func openTerminal(
        in workspace: Workspace, activate: Bool = true, inheritFrom explicit: String? = nil
    ) async -> Session? {
        var params: [String: Any] = [
            "workspaceId": workspace.id,
            "cols": 140,
            "rows": 40,
        ]
        if let inheritFrom = explicit ?? inheritCwdSource(in: workspace) {
            params["inheritCwdFrom"] = inheritFrom
        }
        do {
            let session = try await runtime.rpc("session.create", params, as: Session.self)
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
              let selectedWorkspace
        else { return }
        Task {
            guard let session = await openTerminal(in: selectedWorkspace, activate: false)
            else { return }
            guard selectedWorkspaceId == selectedWorkspace.id else { return }
            mutateCurrentLayout {
                $0.split(fromPane: sourcePaneId, direction: direction, newSessionId: session.id)
            }
            flashPane(session.id)
            requestTerminalFocus()
        }
    }

    func terminateSession(_ session: Session) async {
        let connection = pendingRuntime
        do {
            let workspaceId = workspace(containing: session.id)?.id
            _ = try await connection.rpc("session.kill", ["sessionId": session.id])
            pendingSessionTermination = nil
            TerminalSurfaceCache.shared.evict(session.id)
            await connection.refresh()
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
        pendingServerId = selectedServerId
        editingWorkspaceGroupId = workspaceGroupId
        workspaceGroupName = name
        showingWorkspaceGroupEditor = true
    }

    func presentWorkspaceRename(workspaceId: String, name: String) {
        pendingServerId = selectedServerId
        editingWorkspaceId = workspaceId
        workspaceName = name
        showingWorkspaceEditor = true
    }

    func saveWorkspaceGroup() async {
        let connection = pendingRuntime
        do {
            let name = workspaceGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingWorkspaceGroupId {
                _ = try await connection.rpc("workspaceGroup.update", [
                    "workspaceGroupId": editingWorkspaceGroupId,
                    "name": name,
                ])
            } else {
                let group = try await connection.rpc(
                    "workspaceGroup.create", ["name": name], as: WorkspaceGroup.self
                )
                expandedWorkspaceGroupIds.insert(group.id)
            }
            await connection.refresh()
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
            selectedSessionId = nil
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveWorkspaceName() async {
        guard let editingWorkspaceId else { return }
        let connection = pendingRuntime
        do {
            _ = try await connection.rpc("workspace.update", [
                "workspaceId": editingWorkspaceId,
                "name": workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            await connection.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async {
        let connection = pendingRuntime
        do {
            _ = try await connection.rpc("workspace.remove", ["workspaceId": workspace.id])
            workspaceLayouts.removeValue(forKey: workspace.id)
            expandedWorkspaceIds.remove(workspace.id)
            if selectedWorkspaceId == workspace.id {
                selectedWorkspaceId = nil
                selectedSessionId = nil
            }
            pendingWorkspaceDeletion = nil
            await connection.refresh()
        } catch {
            pendingWorkspaceDeletion = nil
            errorMessage = error.localizedDescription
        }
    }

    func removeWorkspaceGroup(_ group: WorkspaceGroup) async {
        let connection = pendingRuntime
        do {
            _ = try await connection.rpc("workspaceGroup.remove", ["workspaceGroupId": group.id])
            expandedWorkspaceGroupIds.remove(group.id)
            pendingWorkspaceGroupRemoval = nil
            await connection.refresh()
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

    // ---- 布局持久化与对账 ----

    func restoreLayoutIfNeeded() {
        guard !layoutRestored else { return }
        layoutRestored = true
        guard let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data)
        else { return }
        if let serverId = snapshot.selectedServerId { selectedServerId = serverId }
        selectedWorkspaceId = snapshot.selectedWorkspaceId
        workspaceLayouts = snapshot.workspaceLayouts
        leftSidebarVisible = snapshot.leftSidebarVisible
        inspectorVisible = snapshot.inspectorVisible
    }

    var layoutWasRestored: Bool { layoutRestored }

    func reconcileLayoutState() {
        // 选中的服务器被删除时回落到第一台,避免 runtime 静默指向与选中态不一致
        if let selectedServerId, hub.connection(for: selectedServerId) == nil {
            self.selectedServerId = hub.entries.first?.id
        }
        if selectedServerId == nil { selectedServerId = hub.entries.first?.id }
        let loadedConnections = hub.entries.map(\.connection).filter(\.snapshotLoaded)
        guard !loadedConnections.isEmpty else { return }
        // surface 缓存只会为已加载服务器的会话创建,按已加载并集清理是安全的;
        // 布局/展开态可能属于从未上线的服务器,只有全部就绪才收缩,宁多留不误删
        let allLoaded = hub.entries.allSatisfy { $0.connection.snapshotLoaded }
        let validWorkspaceGroupIds = Set(loadedConnections.flatMap { $0.workspaceGroups.map(\.id) })
        if workspaceGroupsInitialized {
            if allLoaded { expandedWorkspaceGroupIds.formIntersection(validWorkspaceGroupIds) }
        } else {
            workspaceGroupsInitialized = true
            expandedWorkspaceGroupIds = validWorkspaceGroupIds
        }
        let validWorkspaceIds = Set(loadedConnections.flatMap { $0.workspaces.map(\.id) })
        let selectedValidWorkspaceIds = Set(runtime.workspaces.map(\.id))
        let aliveSessionIds = Set(
            loadedConnections.flatMap { connection in
                connection.sessions.filter(\.alive).map(\.id)
            }
        )
        TerminalSurfaceCache.shared.retainOnly(aliveSessionIds)
        if allLoaded {
            expandedWorkspaceIds.formIntersection(validWorkspaceIds)
            workspaceLayouts = workspaceLayouts.filter { validWorkspaceIds.contains($0.key) }
        }
        let shouldInitializeWorkspaceExpansion = !workspaceExpansionInitialized
        workspaceExpansionInitialized = true

        for connection in loadedConnections {
            for workspace in connection.workspaces {
                // 布局多端同步:服务端 rev 比本地已应用的新 → 整棵替换(last-writer-wins)。
                // 自己刚推送的修改 rev 已记录在 appliedLayoutRevs,不会被自己的回声覆盖。
                if let serverRev = workspace.layoutRev,
                   serverRev > appliedLayoutRevs[workspace.id] ?? 0 {
                    if let layoutJson = workspace.layout {
                        if let decoded = try? JSONDecoder().decode(
                            WorkspaceTerminalLayout.self, from: Data(layoutJson.utf8)
                        ) {
                            if workspaceLayouts[workspace.id] != decoded {
                                workspaceLayouts[workspace.id] = decoded
                            }
                            if let canonical = Self.encodeLayout(decoded) {
                                lastSyncedLayouts[workspace.id] = canonical
                            }
                            layoutPushFrozen.remove(workspace.id)
                        } else {
                            layoutPushFrozen.insert(workspace.id)
                        }
                    }
                    appliedLayoutRevs[workspace.id] = serverRev
                }
                let workspaceSessions = sessions(in: workspace, on: connection)
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
                    // 无变化不写回:避免每次 refresh 都触发持久化与推送扫描
                    if workspaceLayouts[workspace.id] != layout {
                        workspaceLayouts[workspace.id] = layout
                    }
                } else if !workspaceSessions.isEmpty {
                    // 首次见到该工作区:全部会话进同一窗格作标签
                    let pane = PaneTabGroup(sessionIds: workspaceSessions.map(\.id))
                    workspaceLayouts[workspace.id] = WorkspaceTerminalLayout(root: .pane(pane))
                } else {
                    workspaceLayouts[workspace.id] = WorkspaceTerminalLayout()
                }
            }
        }

        if let selectedWorkspaceId, !selectedValidWorkspaceIds.contains(selectedWorkspaceId) {
            self.selectedWorkspaceId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = runtime.workspaces.first?.id
        }
        guard selectedWorkspaceId != nil else {
            selectedSessionId = nil
            return
        }
        if shouldInitializeWorkspaceExpansion, let selectedWorkspaceId {
            expandedWorkspaceIds.insert(selectedWorkspaceId)
            expandGroupContaining(selectedWorkspaceId)
        }
        syncSelectionFromLayout()
    }

    // ---- 布局多端同步(服务端为真相源;orca 式 rev 单调门 + last-writer-wins) ----

    private static func encodeLayout(_ layout: WorkspaceTerminalLayout) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // 稳定编码,字符串比较即等价比较
        guard let data = try? encoder.encode(layout) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func scheduleLayoutSync() {
        layoutSyncTask?.cancel()
        layoutSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushLayoutsToServers()
        }
    }

    private func pushLayoutsToServers() async {
        for entry in hub.entries {
            let connection = entry.connection
            guard connection.snapshotLoaded else { continue }
            for workspace in connection.workspaces {
                guard !layoutPushFrozen.contains(workspace.id),
                      let layout = workspaceLayouts[workspace.id],
                      let encoded = Self.encodeLayout(layout),
                      encoded != lastSyncedLayouts[workspace.id]
                else { continue }
                // 空工作区且服务端也从没有过布局:不为 "{}" 白白 bump rev
                if layout.root == nil, workspace.layout == nil { continue }
                do {
                    let result = try await connection.rpc(
                        "workspace.setLayout",
                        ["workspaceId": workspace.id, "layout": encoded]
                    )
                    // rpc await 期间可能已应用了别人更新的 rev:簿记只允许单调前进,
                    // 过期的响应直接丢弃,否则会重开 rev 门、覆盖期间的本地编辑
                    if let rev = (result as? [String: Any])?["rev"] as? Int,
                       rev >= appliedLayoutRevs[workspace.id] ?? 0 {
                        appliedLayoutRevs[workspace.id] = rev
                        lastSyncedLayouts[workspace.id] = encoded
                    }
                } catch {
                    // 断线或工作区刚被删:保留 lastSynced 不变,
                    // 重连后的 refresh → reconcile 会再次调度推送
                }
            }
        }
    }

    private func persistLayout() {
        guard layoutRestored else { return }
        let snapshot = WorkbenchLayoutSnapshot(
            selectedServerId: selectedServerId,
            selectedWorkspaceId: selectedWorkspaceId,
            workspaceLayouts: workspaceLayouts,
            leftSidebarVisible: leftSidebarVisible,
            inspectorVisible: inspectorVisible
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.layoutKey)
    }
}
