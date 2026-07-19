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

struct WorkspaceDragPayload: Equatable {
    let workspaceId: String
    let serverId: String
    // provider 可能晚于下一轮拖拽释放;token 防止旧回调清掉新状态
    let token = UUID()
}

@MainActor
final class WorkbenchModel: ObservableObject {
    // 多主机:hub 为每台已配对服务器维持一条常驻连接;
    // runtime 始终指向"当前查看的服务器"的连接,旧的单连接代码路径保持不变。
    let hub: RuntimeHub
    private let fallbackRuntime = RuntimeConnection()

    var runtime: RuntimeConnection {
        if let selectedServerId {
            return hub.connection(for: selectedServerId) ?? fallbackRuntime
        }
        return hub.entries.first?.connection ?? fallbackRuntime
    }

    // ---- 选择与布局 ----
    @Published var selectedServerId: String? { didSet { persistLayout() } }
    @Published var selectedWorkspaceId: String? { didSet { persistLayout() } }
    @Published var selectedSessionId: String?
    @Published var workspaceLayouts: [ScopedResourceID: WorkspaceTerminalLayout] = [:] {
        didSet {
            persistLayout()
            scheduleLayoutSync()
        }
    }
    @Published var expandedWorkspaceGroupIds: Set<ScopedResourceID> = []
    @Published var expandedWorkspaceIds: Set<ScopedResourceID> = []
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
    private var appliedLayoutRevs: [ScopedResourceID: Int] = [:]
    // 上次与服务端达成一致的规范化编码;编码相同 = 无需推送
    private var lastSyncedLayouts: [ScopedResourceID: String] = [:]
    // 服务端布局本机解不开(schema 比本机新):冻结该工作区的推送,
    // 否则旧客户端每次启动都会把旧 schema 布局推回去,把新客户端打回原形
    private var layoutPushFrozen: Set<ScopedResourceID> = []
    private var layoutSyncTask: Task<Void, Never>?

    // ---- 拖拽与快捷键提示 ----
    @Published var draggingTab: TabDragPayload?
    @Published var draggingWorkspace: WorkspaceDragPayload?
    @Published private(set) var cmdHeld = false
    @Published private(set) var controlHeld = false

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

    private var pendingRuntime: RuntimeConnection? {
        hub.connection(for: pendingServerId)
    }

    private func requirePendingRuntime() -> RuntimeConnection? {
        guard let pendingRuntime else {
            errorMessage = "目标服务器已移除，操作已取消"
            return nil
        }
        return pendingRuntime
    }
    @Published var errorMessage: String?

    // ---- 项目目录选择器 ----

    // 只有用户主动编辑过的工作区布局才推送服务端。reconcile 的派生修改
    // (prune / 并入新会话)不算用户意图:被动端若把它推上去,会以更高 rev
    // 覆盖主动端刚做的分屏/移动(last-writer-wins 打架,分屏"闪一下弹回")。
    private var dirtyLayoutWorkspaceIds: Set<ScopedResourceID> = []
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
            let flags = StoredShortcut.normalizedModifiers(event)
            let cmdHeld = flags == .command
            let controlHeld = flags == .control
            Task { @MainActor in
                if self?.cmdHeld != cmdHeld { self?.cmdHeld = cmdHeld }
                if self?.controlHeld != controlHeld { self?.controlHeld = controlHeld }
            }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cmdHeld = false
                self?.controlHeld = false
            }
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
            guard let digit = note.userInfo?["digit"] as? Int else { return }
            MainActor.assumeIsolated {
                self?.selectWorkspace(number: digit)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .acroSelectTabByNumber, object: nil, queue: .main
        ) { [weak self] note in
            guard let digit = note.userInfo?["digit"] as? Int else { return }
            MainActor.assumeIsolated {
                self?.selectTab(number: digit)
            }
        }
    }

    private func scopedID(_ resourceId: String) -> ScopedResourceID? {
        guard let serverId = selectedServerId else { return nil }
        return ScopedResourceID(serverId: serverId, resourceId: resourceId)
    }

    private func serverId(for connection: RuntimeConnection) -> String? {
        hub.entries.first { $0.connection === connection }?.id
            ?? (runtime === connection ? selectedServerId : nil)
    }

    // 快捷键与菜单的统一入口;无效时机的调用由各方法的 guard 空操作
    func perform(_ action: ShortcutAction) {
        switch action {
        case .newTerminalTab:
            if let workspace = selectedWorkspace { requestNewTerminal(in: workspace) }
        case .newWorkspace:
            requestCreateWorkspace()
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
        case .previousWorkspace:
            selectAdjacentWorkspace(offset: -1)
        case .nextWorkspace:
            selectAdjacentWorkspace(offset: 1)
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
        guard let selectedWorkspaceId, let key = scopedID(selectedWorkspaceId) else { return nil }
        return workspaceLayouts[key]
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
              let digit = NumberedShortcutMapper.digit(
                  forIndex: index, count: orderedWorkspaces.count
              )
        else { return nil }
        return digit
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

    func activeSessionCount(
        in workspace: Workspace, on connection: RuntimeConnection? = nil
    ) -> Int {
        sessions(in: workspace, on: connection).count
    }

    var pendingWorkspaceDeletionSessionCount: Int {
        guard let workspace = pendingWorkspaceDeletion, let pendingRuntime else { return 0 }
        return activeSessionCount(in: workspace, on: pendingRuntime)
    }

    func workspace(containing sessionId: String) -> Workspace? {
        runtime.workspaces.first { $0.sessionIds.contains(sessionId) }
    }

    func session(_ sessionId: String) -> Session? {
        activeSessions.first { $0.id == sessionId }
    }

    // 标签标题不再追加 " · N" 同名序号:靠终端 OSC 标题天然区分同目录的多个终端,
    // 都不设标题的裸 shell 本无语义差异,序号不携带信息。on: 形参保留仅为调用点零改动。
    func sessionDisplayName(_ session: Session, on connection: RuntimeConnection? = nil) -> String {
        Self.sessionTitle(session)
    }

    // 标题优先级:终端 OSC 标题(vim/agent/ssh 等主动设置)> 工作目录尾段 > "终端"。
    // OSC 标题由 daemon 从屏幕状态采集写入 session.title,跨端一致。
    static func sessionTitle(_ session: Session) -> String {
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let last = (session.cwd as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "终端" : last
    }

    // ---- 布局变更入口(集中同步选中态与持久化) ----

    private func mutateCurrentLayout(_ transform: (inout WorkspaceTerminalLayout) -> Void) {
        guard let selectedWorkspaceId, let key = scopedID(selectedWorkspaceId) else { return }
        var layout = workspaceLayouts[key] ?? WorkspaceTerminalLayout()
        transform(&layout)
        dirtyLayoutWorkspaceIds.insert(key)
        workspaceLayouts[key] = layout
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

    // ---- 终端占用锁(orca presence lock 的显式变体) ----

    // 被其他设备占用时返回占用者;自己占用或无人占用返回 nil
    func focusOccupant(
        _ sessionId: String, on connection: RuntimeConnection? = nil
    ) -> SessionFocus? {
        let source = connection ?? runtime
        guard let owner = source.focusOwners[sessionId],
              !source.deviceId.isEmpty,
              owner.deviceId != source.deviceId
        else { return nil }
        return owner
    }

    // 本地交互(点标签/点终端/侧边栏选择)时静默认领;
    // 已被他人占用则不抢——由蒙版上的按钮显式接管
    func maybeClaimFocus(_ sessionId: String) {
        guard focusOccupant(sessionId) == nil,
              runtime.focusOwners[sessionId]?.deviceId != runtime.deviceId
        else { return }
        claimFocus(sessionId)
    }

    // 显式接管:蒙版按钮直达,force 夺取占用权
    func claimFocus(_ sessionId: String, force: Bool = false) {
        let connection = runtime
        Task {
            _ = try? await connection.rpc(
                "session.claimFocus", ["sessionId": sessionId, "force": force])
            await connection.refresh()
        }
    }

    func showSession(_ session: Session, flash: Bool = true) {
        guard let workspace = workspace(containing: session.id) else { return }
        selectedWorkspaceId = workspace.id
        mutateCurrentLayout { $0.adopt(session.id) }
        expandGroupContaining(workspace.id)
        if let key = scopedID(workspace.id) { expandedWorkspaceIds.insert(key) }
        if flash { flashPane(session.id) }
        requestTerminalFocus()
        maybeClaimFocus(session.id)
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        if let key = scopedID(workspace.id) { expandedWorkspaceIds.insert(key) }
        if scopedID(workspace.id).flatMap({ workspaceLayouts[$0] })?.root == nil,
           let session = sessions(in: workspace).first {
            mutateCurrentLayout { $0.adopt(session.id) }
        }
        syncSelectionFromLayout()
        if let focusedSessionId = currentLayout?.focusedSessionId {
            flashPane(focusedSessionId)
            requestTerminalFocus()
            maybeClaimFocus(focusedSessionId)
        }
    }

    func selectWorkspace(at index: Int) {
        let ordered = orderedWorkspaces
        guard ordered.indices.contains(index) else { return }
        selectWorkspace(ordered[index])
    }

    func selectWorkspace(number: Int) {
        guard let index = NumberedShortcutMapper.index(
            forDigit: number, count: orderedWorkspaces.count
        ) else { return }
        selectWorkspace(at: index)
    }

    func selectAdjacentWorkspace(offset: Int) {
        let ordered = orderedWorkspaces
        guard !ordered.isEmpty,
              let selectedWorkspaceId,
              let index = ordered.firstIndex(where: { $0.id == selectedWorkspaceId })
        else { return }
        selectWorkspace(ordered[(index + offset + ordered.count) % ordered.count])
    }

    func focusSession(_ session: Session, flash: Bool = false) {
        guard let workspace = workspace(containing: session.id) else { return }
        if selectedWorkspaceId != workspace.id { selectedWorkspaceId = workspace.id }
        mutateCurrentLayout { $0.adopt(session.id) }
        if let key = scopedID(workspace.id) { expandedWorkspaceIds.insert(key) }
        expandGroupContaining(workspace.id)
        if flash { flashPane(session.id) }
        maybeClaimFocus(session.id)
    }

    func focusSessionId(_ sessionId: String) {
        guard let session = session(sessionId) else { return }
        focusSession(session)
    }

    // ---- 标签动作 ----

    func selectTab(_ sessionId: String, inPane paneId: String) {
        mutateCurrentLayout { $0.selectTab(sessionId, inPane: paneId) }
        maybeClaimFocus(sessionId)
        flashPane(sessionId)
        requestTerminalFocus()
    }

    func selectTab(number: Int) {
        guard let target = currentLayout?.tab(number: number) else { return }
        selectTab(target.sessionId, inPane: target.paneId)
    }

    func tabShortcutDigit(_ sessionId: String, inPane paneId: String) -> Int? {
        guard currentLayout?.focusedPaneId == paneId,
              let pane = currentLayout?.root?.pane(withId: paneId),
              let index = pane.sessionIds.firstIndex(of: sessionId)
        else { return nil }
        return NumberedShortcutMapper.digit(forIndex: index, count: pane.sessionIds.count)
    }

    // 布局层移除(surface 自行退出、会话已死时用);活会话的"关闭标签"走 requestKillTab
    func closeTab(_ sessionId: String) {
        guard let serverId = selectedServerId, let workspaceId = selectedWorkspaceId else { return }
        closeTab(sessionId, workspaceId: workspaceId, serverId: serverId)
    }

    func closeTab(_ sessionId: String, workspaceId: String, serverId: String) {
        let key = ScopedResourceID(serverId: serverId, resourceId: workspaceId)
        guard var layout = workspaceLayouts[key] else { return }
        layout.removeTab(sessionId)
        dirtyLayoutWorkspaceIds.insert(key)
        workspaceLayouts[key] = layout
        if selectedServerId == serverId, selectedWorkspaceId == workspaceId {
            syncSelectionFromLayout()
            requestTerminalFocus()
        }
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
            let connection = runtime
            Task { await terminateSession(session, on: connection) }
        }
    }

    func requestKillFocusedTab() {
        guard let sessionId = currentLayout?.focusedSessionId else { return }
        requestKillTab(sessionId)
    }

    func selectAdjacentTab(offset: Int) {
        guard let target = currentLayout?.adjacentTab(offset: offset) else { return }
        selectTab(target.sessionId, inPane: target.paneId)
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

    func endWorkspaceDrag(_ payload: WorkspaceDragPayload) {
        if draggingWorkspace == payload { draggingWorkspace = nil }
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
            maybeClaimFocus(sessionId)
        }
        requestTerminalFocus()
    }

    // ---- 终端动作 ----

    func requestNewTerminal(
        in workspace: Workspace, paneId: String? = nil, inheritFrom: String? = nil
    ) {
        let connection = runtime
        selectedWorkspaceId = workspace.id
        expandGroupContaining(workspace.id)
        if let key = scopedID(workspace.id) { expandedWorkspaceIds.insert(key) }
        if let paneId { mutateCurrentLayout { $0.focusedPaneId = paneId } }
        Task { _ = await openTerminal(in: workspace, inheritFrom: inheritFrom, on: connection) }
    }

    // 路径继承源:聚焦终端优先;fallback 工作区第一个存活终端;都没有交给服务端(家目录)
    private func inheritCwdSource(in workspace: Workspace, on connection: RuntimeConnection) -> String? {
        if runtime === connection, selectedWorkspaceId == workspace.id,
           let focused = currentLayout?.focusedSessionId,
           session(focused) != nil {
            return focused
        }
        return sessions(in: workspace, on: connection).first?.id
    }

    @discardableResult
    private func openTerminal(
        in workspace: Workspace, activate: Bool = true, inheritFrom explicit: String? = nil,
        on explicitConnection: RuntimeConnection? = nil
    ) async -> Session? {
        let connection = explicitConnection ?? runtime
        var params: [String: Any] = [
            "workspaceId": workspace.id,
            "cols": 140,
            "rows": 40,
        ]
        if let inheritFrom = explicit ?? inheritCwdSource(in: workspace, on: connection) {
            params["inheritCwdFrom"] = inheritFrom
        }
        do {
            let session = try await connection.rpc("session.create", params, as: Session.self)
            await connection.refresh()
            if activate, runtime === connection { showSession(session) }
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
        let connection = runtime
        Task {
            guard let session = await openTerminal(
                in: selectedWorkspace, activate: false, on: connection)
            else { return }
            guard runtime === connection, selectedWorkspaceId == selectedWorkspace.id else { return }
            mutateCurrentLayout {
                $0.split(fromPane: sourcePaneId, direction: direction, newSessionId: session.id)
            }
            flashPane(session.id)
            requestTerminalFocus()
            maybeClaimFocus(session.id)
        }
    }

    func terminateSession(
        _ session: Session, on explicitConnection: RuntimeConnection? = nil
    ) async {
        guard let connection = explicitConnection ?? requirePendingRuntime() else {
            pendingSessionTermination = nil
            return
        }
        let targetServerId = serverId(for: connection)
        do {
            let workspaceId = connection.workspaces.first { $0.sessionIds.contains(session.id) }?.id
            _ = try await connection.rpc("session.kill", ["sessionId": session.id])
            pendingSessionTermination = nil
            if let targetServerId {
                TerminalSurfaceCache.shared.evict(serverId: targetServerId, sessionId: session.id)
            }
            await connection.refresh()
            if let workspaceId, let targetServerId {
                let key = ScopedResourceID(serverId: targetServerId, resourceId: workspaceId)
                if var layout = workspaceLayouts[key] {
                    layout.removeTab(session.id)
                    dirtyLayoutWorkspaceIds.insert(key)
                    workspaceLayouts[key] = layout
                    if runtime === connection, selectedWorkspaceId == workspaceId {
                        syncSelectionFromLayout()
                        requestTerminalFocus()
                    }
                }
            }
        } catch {
            pendingSessionTermination = nil
            errorMessage = error.localizedDescription
        }
    }

    // ---- 工作区与分组动作 ----

    func toggleWorkspaceGroup(_ workspaceGroupId: String, serverId: String) {
        let key = ScopedResourceID(serverId: serverId, resourceId: workspaceGroupId)
        if expandedWorkspaceGroupIds.contains(key) {
            expandedWorkspaceGroupIds.remove(key)
        } else {
            expandedWorkspaceGroupIds.insert(key)
        }
    }

    func toggleWorkspace(_ workspaceId: String, serverId: String) {
        let key = ScopedResourceID(serverId: serverId, resourceId: workspaceId)
        if expandedWorkspaceIds.contains(key) {
            expandedWorkspaceIds.remove(key)
        } else {
            expandedWorkspaceIds.insert(key)
        }
    }

    private func expandGroupContaining(_ workspaceId: String) {
        guard let group = workspaceGroup(containing: workspaceId), let key = scopedID(group.id)
        else { return }
        expandedWorkspaceGroupIds.insert(key)
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
        guard let connection = requirePendingRuntime(), let targetServerId = serverId(for: connection)
        else { return }
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
                expandedWorkspaceGroupIds.insert(ScopedResourceID(
                    serverId: targetServerId,
                    resourceId: group.id
                ))
            }
            await connection.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestCreateWorkspace(in workspaceGroupId: String? = nil) {
        let connection = runtime
        Task { await createWorkspace(in: workspaceGroupId, on: connection) }
    }

    private func createWorkspace(
        in workspaceGroupId: String? = nil, on connection: RuntimeConnection
    ) async {
        do {
            var params: [String: Any] = [:]
            if let workspaceGroupId { params["workspaceGroupId"] = workspaceGroupId }
            let workspace = try await connection.rpc("workspace.create", params, as: Workspace.self)
            await connection.refresh()
            let shouldActivate = runtime === connection
            if shouldActivate {
                if let workspaceGroupId, let key = scopedID(workspaceGroupId) {
                    expandedWorkspaceGroupIds.insert(key)
                }
                if let key = scopedID(workspace.id) { expandedWorkspaceIds.insert(key) }
                selectedWorkspaceId = workspace.id
                selectedSessionId = nil
            }
            // 终端应用的工作区开箱即用:直接带上第一个终端,不要求再点一次
            _ = await openTerminal(in: workspace, activate: shouldActivate, on: connection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveWorkspaceName() async {
        guard let editingWorkspaceId else { return }
        guard let connection = requirePendingRuntime() else { return }
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
        guard let connection = requirePendingRuntime() else {
            pendingWorkspaceDeletion = nil
            return
        }
        let targetServerId = serverId(for: connection)
        do {
            let activeSessionIds = Set(sessions(in: workspace, on: connection).map(\.id))
            for sessionId in activeSessionIds {
                _ = try await connection.rpc("session.kill", ["sessionId": sessionId])
            }
            for _ in 0..<30 where !activeSessionIds.isEmpty {
                let remoteSessions = try await connection.rpc("session.list", as: [Session].self)
                if !remoteSessions.contains(where: {
                    $0.alive && activeSessionIds.contains($0.id)
                }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            _ = try await connection.rpc(
                "workspace.remove", ["workspaceId": workspace.id, "force": true]
            )
            if let targetServerId {
                for sessionId in workspace.sessionIds {
                    TerminalSurfaceCache.shared.evict(
                        serverId: targetServerId,
                        sessionId: sessionId
                    )
                }
            }
            if let targetServerId {
                let key = ScopedResourceID(serverId: targetServerId, resourceId: workspace.id)
                workspaceLayouts.removeValue(forKey: key)
                appliedLayoutRevs.removeValue(forKey: key)
                lastSyncedLayouts.removeValue(forKey: key)
                layoutPushFrozen.remove(key)
                dirtyLayoutWorkspaceIds.remove(key)
            }
            if runtime === connection {
                if let key = scopedID(workspace.id) { expandedWorkspaceIds.remove(key) }
            }
            if runtime === connection, selectedWorkspaceId == workspace.id {
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
        guard let connection = requirePendingRuntime() else {
            pendingWorkspaceGroupRemoval = nil
            return
        }
        let targetServerId = serverId(for: connection)
        do {
            _ = try await connection.rpc("workspaceGroup.remove", ["workspaceGroupId": group.id])
            if let targetServerId {
                expandedWorkspaceGroupIds.remove(ScopedResourceID(
                    serverId: targetServerId,
                    resourceId: group.id
                ))
            }
            pendingWorkspaceGroupRemoval = nil
            await connection.refresh()
        } catch {
            pendingWorkspaceGroupRemoval = nil
            errorMessage = error.localizedDescription
        }
    }

    func requestMoveWorkspace(_ workspace: Workspace, to group: WorkspaceGroup?) {
        let connection = runtime
        Task { await moveWorkspace(workspace, to: group, on: connection) }
    }

    private func moveWorkspace(
        _ workspace: Workspace, to group: WorkspaceGroup?, on connection: RuntimeConnection
    ) async {
        do {
            _ = try await connection.rpc("workspace.update", [
                "workspaceId": workspace.id,
                "workspaceGroupId": group?.id ?? NSNull(),
            ])
            if runtime === connection, let group, let key = scopedID(group.id) {
                expandedWorkspaceGroupIds.insert(key)
            }
            await connection.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // 拖拽重排:workspaceGroupId 为 nil 表示未分组区
    func requestReorderWorkspace(
        _ workspaceId: String, toGroup workspaceGroupId: String?, index: Int
    ) {
        let connection = runtime
        Task {
            await reorderWorkspace(
                workspaceId, toGroup: workspaceGroupId, index: index, on: connection)
        }
    }

    private func reorderWorkspace(
        _ workspaceId: String, toGroup workspaceGroupId: String?, index: Int,
        on connection: RuntimeConnection
    ) async {
        do {
            _ = try await connection.rpc("workspace.reorder", [
                "workspaceId": workspaceId,
                "workspaceGroupId": workspaceGroupId ?? NSNull(),
                "index": index,
            ])
            if runtime === connection, let workspaceGroupId {
                if let key = scopedID(workspaceGroupId) {
                    expandedWorkspaceGroupIds.insert(key)
                }
            }
            await connection.refresh()
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
        let restoredServerId = snapshot.selectedServerId ?? selectedServerId
        if let serverId = snapshot.selectedServerId { selectedServerId = serverId }
        selectedWorkspaceId = snapshot.selectedWorkspaceId
        workspaceLayouts = snapshot.workspaceLayouts(scopedTo: restoredServerId)
        leftSidebarVisible = snapshot.leftSidebarVisible
        inspectorVisible = snapshot.inspectorVisible
    }

    var layoutWasRestored: Bool { layoutRestored }

    func reconcileLayoutState() {
        // 选中的服务器被删除时回落到第一台,避免 runtime 静默指向与选中态不一致
        if let selectedServerId, hub.connection(for: selectedServerId) == nil {
            self.selectedServerId = hub.entries.first?.id
            selectedWorkspaceId = nil
            selectedSessionId = nil
        }
        if selectedServerId == nil { selectedServerId = hub.entries.first?.id }
        let loadedEntries = hub.entries.filter { $0.connection.snapshotLoaded }
        guard !loadedEntries.isEmpty else { return }
        // surface 缓存只会为已加载服务器的会话创建,按已加载并集清理是安全的;
        // 布局/展开态可能属于从未上线的服务器,只有全部就绪才收缩,宁多留不误删
        let allLoaded = hub.entries.allSatisfy { $0.connection.snapshotLoaded }
        let validWorkspaceGroupIds = Set(loadedEntries.flatMap { entry in
            entry.connection.workspaceGroups.map {
                ScopedResourceID(serverId: entry.id, resourceId: $0.id)
            }
        })
        if workspaceGroupsInitialized {
            if allLoaded { expandedWorkspaceGroupIds.formIntersection(validWorkspaceGroupIds) }
        } else {
            workspaceGroupsInitialized = true
            expandedWorkspaceGroupIds = validWorkspaceGroupIds
        }
        let validWorkspaceKeys = Set(loadedEntries.flatMap { entry in
            entry.connection.workspaces.map {
                ScopedResourceID(serverId: entry.id, resourceId: $0.id)
            }
        })
        let selectedValidWorkspaceIds = Set(runtime.workspaces.map(\.id))
        let aliveSessionIds = Set(
            loadedEntries.flatMap { entry in
                entry.connection.sessions.filter(\.alive).map {
                    ScopedResourceID(serverId: entry.id, resourceId: $0.id)
                }
            }
        )
        TerminalSurfaceCache.shared.retainOnly(aliveSessionIds)
        if allLoaded {
            expandedWorkspaceIds.formIntersection(validWorkspaceKeys)
            workspaceLayouts = workspaceLayouts.filter { validWorkspaceKeys.contains($0.key) }
        }
        let shouldInitializeWorkspaceExpansion = !workspaceExpansionInitialized
        workspaceExpansionInitialized = true

        for entry in loadedEntries {
            let connection = entry.connection
            for workspace in connection.workspaces {
                let key = ScopedResourceID(serverId: entry.id, resourceId: workspace.id)
                // 布局多端同步:服务端 rev 比本地已应用的新 → 整棵替换(last-writer-wins)。
                // 自己刚推送的修改 rev 已记录在 appliedLayoutRevs,不会被自己的回声覆盖。
                if let serverRev = workspace.layoutRev,
                   serverRev > appliedLayoutRevs[key] ?? 0 {
                    if let layoutJson = workspace.layout {
                        if let decoded = try? JSONDecoder().decode(
                            WorkspaceTerminalLayout.self, from: Data(layoutJson.utf8)
                        ) {
                            if workspaceLayouts[key] != decoded {
                                workspaceLayouts[key] = decoded
                            }
                            if let canonical = Self.encodeLayout(decoded) {
                                lastSyncedLayouts[key] = canonical
                            }
                            layoutPushFrozen.remove(key)
                        } else {
                            layoutPushFrozen.insert(key)
                        }
                    }
                    appliedLayoutRevs[key] = serverRev
                }
                let workspaceSessions = sessions(in: workspace, on: connection)
                let validSessionIds = Set(workspaceSessions.map(\.id))
                if var layout = workspaceLayouts[key] {
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
                    if workspaceLayouts[key] != layout {
                        workspaceLayouts[key] = layout
                    }
                } else if !workspaceSessions.isEmpty {
                    // 首次见到该工作区:全部会话进同一窗格作标签
                    let pane = PaneTabGroup(sessionIds: workspaceSessions.map(\.id))
                    workspaceLayouts[key] = WorkspaceTerminalLayout(root: .pane(pane))
                } else {
                    workspaceLayouts[key] = WorkspaceTerminalLayout()
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
            if let key = scopedID(selectedWorkspaceId) { expandedWorkspaceIds.insert(key) }
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
                let key = ScopedResourceID(serverId: entry.id, resourceId: workspace.id)
                guard dirtyLayoutWorkspaceIds.contains(key),
                      !layoutPushFrozen.contains(key),
                      let layout = workspaceLayouts[key],
                      let encoded = Self.encodeLayout(layout),
                      encoded != lastSyncedLayouts[key]
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
                       rev >= appliedLayoutRevs[key] ?? 0 {
                        appliedLayoutRevs[key] = rev
                        lastSyncedLayouts[key] = encoded
                    }
                    // rpc await 期间用户又编辑过则保持 dirty,下一轮继续推
                    if workspaceLayouts[key].flatMap(Self.encodeLayout) == encoded {
                        dirtyLayoutWorkspaceIds.remove(key)
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
