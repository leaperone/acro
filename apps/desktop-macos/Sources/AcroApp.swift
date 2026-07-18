// Acro Desktop:工作区侧边栏 + libghostty 终端表面。
// 终端渲染由 libghostty 完成,surface command 跑 `acro attach <sessionId>`,
// 会话本体永远活在 Runtime 侧的 terminal daemon 里。

import AppKit
import SwiftUI

final class AcroAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKeyDown(event, firstResponder: event.window?.firstResponder)
        }
    }

    static func handleKeyDown(_ event: NSEvent, firstResponder: NSResponder?) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return event }
        guard !event.isARepeat else { return nil }
        (firstResponder as? AcroTerminalNSView)?.closePaneFromShortcut()
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

struct WorkbenchActions {
    let newWorkspaceGroup: () -> Void
    let newWorkspace: () -> Void
    let newTerminal: () -> Void
    let showCommandPalette: () -> Void
    let splitRight: () -> Void
    let splitDown: () -> Void
    let focusPreviousPane: () -> Void
    let focusNextPane: () -> Void
    let closePane: () -> Void
    let toggleLeftSidebar: () -> Void
    let toggleInspector: () -> Void
    let previousSession: () -> Void
    let nextSession: () -> Void
    let selectSessionAtIndex: (Int) -> Void
    let focusTerminal: () -> Void
    let closeSession: () -> Void
    let canCreateTerminal: Bool
    let canSplitTerminal: Bool
    let canNavigatePanes: Bool
    let canClosePane: Bool
    let canNavigateSessions: Bool
    let canFocusTerminal: Bool
    let canCloseSession: Bool
    let sessionCount: Int
    let leftSidebarVisible: Bool
    let inspectorVisible: Bool
}

private struct WorkbenchActionsKey: FocusedValueKey {
    typealias Value = WorkbenchActions
}

extension FocusedValues {
    var workbenchActions: WorkbenchActions? {
        get { self[WorkbenchActionsKey.self] }
        set { self[WorkbenchActionsKey.self] = newValue }
    }
}

struct AcroWorkbenchCommands: Commands {
    @FocusedValue(\.workbenchActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建终端", systemImage: "terminal") {
                actions?.newTerminal()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canCreateTerminal != true)

            Button("新建工作区", systemImage: "plus") {
                actions?.newWorkspace()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("新建分组", systemImage: "folder.badge.plus") {
                actions?.newWorkspaceGroup()
            }
        }

        CommandMenu("工作台") {
            Button("命令面板", systemImage: "command") {
                actions?.showCommandPalette()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button(actions?.leftSidebarVisible == true ? "隐藏左侧栏" : "显示左侧栏", systemImage: "sidebar.left") {
                actions?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button(actions?.inspectorVisible == true ? "隐藏右侧栏" : "显示右侧栏", systemImage: "sidebar.right") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("向右分屏", systemImage: "rectangle.split.2x1") {
                actions?.splitRight()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(actions?.canSplitTerminal != true)

            Button("向下分屏", systemImage: "rectangle.split.1x2") {
                actions?.splitDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions?.canSplitTerminal != true)

            Button("上一个窗格", systemImage: "chevron.left") {
                actions?.focusPreviousPane()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(actions?.canNavigatePanes != true)

            Button("下一个窗格", systemImage: "chevron.right") {
                actions?.focusNextPane()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(actions?.canNavigatePanes != true)

            Button("关闭窗格", systemImage: "rectangle.split.2x1") {
                actions?.closePane()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions?.canClosePane != true)

            Divider()

            Button("上一个终端", systemImage: "chevron.left") {
                actions?.previousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateSessions != true)

            Button("下一个终端", systemImage: "chevron.right") {
                actions?.nextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateSessions != true)

            Menu("切换终端", systemImage: "rectangle.stack") {
                ForEach(1...9, id: \.self) { number in
                    Button("终端 \(number)") {
                        actions?.selectSessionAtIndex(number - 1)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(number))),
                        modifiers: .command
                    )
                    .disabled((actions?.sessionCount ?? 0) < number)
                }
            }
            .disabled((actions?.sessionCount ?? 0) == 0)

            Button("聚焦终端", systemImage: "text.cursor") {
                actions?.focusTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(actions?.canFocusTerminal != true)

            Button("关闭终端", systemImage: "xmark") {
                actions?.closeSession()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(actions?.canCloseSession != true)
        }
    }
}

@main
struct AcroApp: App {
    @NSApplicationDelegateAdaptor(AcroAppDelegate.self) private var appDelegate
    @StateObject private var runtime = RuntimeConnection()

    var body: some Scene {
        WindowGroup("Acro") {
            ContentView()
                .environmentObject(runtime)
                .onAppear {
                    _ = Ghostty.shared // 初始化 libghostty
                    if let config = ClientConfig.load() {
                        runtime.connect(config: config)
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            AcroWorkbenchCommands()
        }
    }
}

// 解析 attach 命令:node + acro CLI 的绝对路径(GUI 进程没有用户 PATH)
enum AttachCommand {
    static func resolve(sessionId: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let runtimeArguments = runtimeProgramArguments()
        let node = [
            env["ACRO_NODE"],
            runtimeArguments?.first,
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "node"
        let cli = env["ACRO_CLI_PATH"]
            ?? runtimeCliPath(from: runtimeArguments)
            ?? "\(NSHomeDirectory())/project/acro/apps/cli/src/cli.ts"
        return [node, cli, "attach", sessionId].map(shellQuote).joined(separator: " ")
    }

    private static func runtimeProgramArguments() -> [String]? {
        let path = "\(NSHomeDirectory())/Library/LaunchAgents/one.leaper.acro.runtime.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String]
        else { return nil }
        return arguments
    }

    private static func runtimeCliPath(from arguments: [String]?) -> String? {
        guard let runtimeScript = arguments?.dropFirst().first else { return nil }
        var root = URL(fileURLWithPath: runtimeScript)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("apps/cli/src/cli.ts").path
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeConnection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = true
    @State private var selectedWorkspaceId: String?
    @State private var selectedProjectId: String?
    @State private var selectedSessionId: String?
    @State private var workspaceLayouts: [String: WorkspaceTerminalLayout] = [:]
    @State private var terminalFocusRequest = 0
    @State private var layoutRestored = false
    @State private var workspaceGroupsInitialized = false
    @State private var expandedWorkspaceGroupIds: Set<String> = []
    @State private var expandedWorkspaceIds: Set<String> = []
    @State private var showingWorkspaceGroupEditor = false
    @State private var editingWorkspaceGroupId: String?
    @State private var workspaceGroupName = ""
    @State private var newWorkspaceGroupId: String?
    @State private var showingWorkspaceEditor = false
    @State private var editingWorkspaceId: String?
    @State private var workspaceName = ""
    @State private var pendingWorkspaceDeletion: [String: Any]?
    @State private var pendingWorkspaceGroupRemoval: [String: Any]?
    @State private var pendingSessionTermination: [String: Any]?
    @State private var projectPickerWorkspace: [String: Any]?
    @State private var terminalProjectPickerWorkspace: [String: Any]?
    @State private var projectQuery = ""
    @State private var showingCommandPalette = false
    @State private var hoveredWorkspaceGroupId: String?
    @State private var hoveredWorkspaceId: String?
    @State private var errorMessage: String?
    @AppStorage("acro.desktop.workbench.layout.v1") private var persistedLayout = ""

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                GeometryReader { geometry in
                    HSplitView {
                        terminalContent
                            .frame(minWidth: 440, maxHeight: .infinity)
                            .layoutPriority(1)

                        if inspectorVisible, geometry.size.width >= 720 {
                            inspector
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                                .frame(maxHeight: .infinity)
                        }
                    }
                }
                .navigationTitle(windowTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCommandPalette = true
                        } label: {
                            Image(systemName: "command")
                        }
                        .help("命令面板")
                        .accessibilityLabel("命令面板")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            inspectorVisible.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                        .accessibilityLabel(inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                    }
                }
            }

            if showingCommandPalette {
                CommandPalette(items: commandPaletteItems) {
                    showingCommandPalette = false
                    requestTerminalFocus()
                }
                .zIndex(10)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .onChange(of: runtime.snapshotLoaded, initial: true) { _, loaded in
            guard loaded else { return }
            let shouldFocusTerminal = !layoutRestored
            restoreLayoutIfNeeded()
            reconcileLayoutState()
            if shouldFocusTerminal {
                DispatchQueue.main.async { requestTerminalFocus() }
            }
        }
        .onChange(of: runtime.snapshotRevision) { _, _ in
            guard runtime.snapshotLoaded, layoutRestored else { return }
            reconcileLayoutState()
        }
        .onChange(of: workspaceLayouts) { _, _ in
            persistLayout()
        }
        .onChange(of: selectedWorkspaceId) { _, _ in
            persistLayout()
        }
        .onChange(of: columnVisibility) { _, _ in
            persistLayout()
        }
        .onChange(of: inspectorVisible) { _, _ in
            persistLayout()
        }
        .alert(
            editingWorkspaceGroupId == nil ? "新建分组" : "重命名分组",
            isPresented: $showingWorkspaceGroupEditor
        ) {
            TextField("名称", text: $workspaceGroupName)
            Button("取消", role: .cancel) {}
            Button(editingWorkspaceGroupId == nil ? "创建" : "保存") {
                Task { await saveWorkspaceGroup() }
            }
            .disabled(workspaceGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            editingWorkspaceId == nil ? "新建工作区" : "重命名工作区",
            isPresented: $showingWorkspaceEditor
        ) {
            TextField("名称", text: $workspaceName)
            Button("取消", role: .cancel) {}
            Button(editingWorkspaceId == nil ? "创建" : "保存") {
                Task { await saveWorkspace() }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .confirmationDialog("删除工作区？", isPresented: deletionPresented) {
            Button("删除", role: .destructive) {
                if let workspace = pendingWorkspaceDeletion {
                    Task { await deleteWorkspace(workspace) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行中的会话会阻止删除。")
        }
        .confirmationDialog("解散分组？", isPresented: workspaceGroupRemovalPresented) {
            Button("解散", role: .destructive) {
                if let group = pendingWorkspaceGroupRemoval {
                    Task { await removeWorkspaceGroup(group) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("工作区会保留，并移到未分组区域。")
        }
        .confirmationDialog("关闭终端？", isPresented: terminationPresented) {
            Button("关闭", role: .destructive) {
                if let session = pendingSessionTermination {
                    Task { await terminateSession(session) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("终端中的运行进程会被结束。")
        }
        .sheet(isPresented: projectPickerPresented) {
            projectPicker
        }
        .sheet(isPresented: terminalProjectPickerPresented) {
            terminalProjectPicker
        }
        .focusedSceneValue(\.workbenchActions, workbenchActions)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("工作区")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(runtime.connected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .help(runtime.connected ? "Runtime 已连接" : "Runtime 未连接")
                Menu {
                    Button("新建工作区", systemImage: "square.stack.3d.up.badge.plus") {
                        presentWorkspaceEditor(workspaceId: nil, name: "")
                    }
                    Button("新建分组", systemImage: "folder.badge.plus") {
                        presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建")
                .accessibilityLabel("新建")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if runtime.workspaceGroups.isEmpty && runtime.workspaces.isEmpty {
                        Button {
                            presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
                        } label: {
                            Label("新建分组", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(runtime.workspaceGroups.indices, id: \.self) { index in
                            workspaceGroupRow(runtime.workspaceGroups[index])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !ungroupedWorkspaces.isEmpty {
                            if !runtime.workspaceGroups.isEmpty {
                                Text("未分组")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                            }
                            ForEach(ungroupedWorkspaces.indices, id: \.self) { index in
                                workspaceRow(ungroupedWorkspaces[index])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .background(.bar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 320)
    }

    private var workbenchActions: WorkbenchActions {
        WorkbenchActions(
            newWorkspaceGroup: {
                presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
            },
            newWorkspace: { presentWorkspaceEditor(workspaceId: nil, name: "") },
            newTerminal: {
                if let selectedWorkspace { requestNewTerminal(in: selectedWorkspace) }
            },
            showCommandPalette: { showingCommandPalette = true },
            splitRight: { splitTerminal(.horizontal) },
            splitDown: { splitTerminal(.vertical) },
            focusPreviousPane: { focusAdjacentPane(offset: -1) },
            focusNextPane: { focusAdjacentPane(offset: 1) },
            closePane: { closeFocusedPane() },
            toggleLeftSidebar: {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            },
            toggleInspector: { inspectorVisible.toggle() },
            previousSession: { selectAdjacentSession(offset: -1) },
            nextSession: { selectAdjacentSession(offset: 1) },
            selectSessionAtIndex: { selectSession(at: $0) },
            focusTerminal: { requestTerminalFocus() },
            closeSession: {
                if let selectedSession { pendingSessionTermination = selectedSession }
            },
            canCreateTerminal: selectedWorkspace.map { !projects(in: $0).isEmpty } ?? false,
            canSplitTerminal: selectedWorkspace != nil && selectedProject != nil && selectedSession != nil,
            canNavigatePanes: currentLayout?.root?.sessionIds.count ?? 0 > 1,
            canClosePane: currentLayout?.root != nil,
            canNavigateSessions: currentWorkspaceSessions.count > 1,
            canFocusTerminal: selectedSession != nil,
            canCloseSession: selectedSession != nil,
            sessionCount: currentWorkspaceSessions.count,
            leftSidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: inspectorVisible
        )
    }

    private var activeSessions: [[String: Any]] {
        let workspaceSessionIds = Set(runtime.workspaces.flatMap { strings($0["sessionIds"]) })
        return runtime.sessions.filter {
            ($0["alive"] as? Bool ?? false) && workspaceSessionIds.contains(string($0, "id"))
        }
    }

    private var activeSessionIds: [String] {
        activeSessions.map { string($0, "id") }
    }

    private var currentWorkspaceSessions: [[String: Any]] {
        selectedWorkspace.map(sessions(in:)) ?? []
    }

    private var currentLayout: WorkspaceTerminalLayout? {
        guard let selectedWorkspaceId else { return nil }
        return workspaceLayouts[selectedWorkspaceId]
    }

    private var selectedWorkspace: [String: Any]? {
        guard let selectedWorkspaceId else { return nil }
        return runtime.workspaces.first { string($0, "id") == selectedWorkspaceId }
    }

    private var selectedProject: [String: Any]? {
        guard let selectedProjectId,
              let selectedWorkspace,
              strings(selectedWorkspace["projectIds"]).contains(selectedProjectId)
        else { return nil }
        return runtime.projects.first { string($0, "id") == selectedProjectId }
    }

    private var selectedSession: [String: Any]? {
        guard let selectedSessionId else { return nil }
        return activeSessions.first { string($0, "id") == selectedSessionId }
    }

    private var windowTitle: String {
        if let selectedProject { return string(selectedProject, "name") }
        if let selectedWorkspace { return string(selectedWorkspace, "name") }
        return "Acro"
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let root = currentLayout?.root {
            terminalLayoutView(root)
        } else if let selectedWorkspace {
            ContentUnavailableView {
                Label("没有终端", systemImage: "terminal")
            } actions: {
                if projects(in: selectedWorkspace).isEmpty {
                    Button("添加项目") {
                        projectPickerWorkspace = selectedWorkspace
                    }
                } else {
                    Button("新建终端") {
                        requestNewTerminal(in: selectedWorkspace)
                    }
                }
            }
        } else if runtime.connected {
            ContentUnavailableView("选择工作区", systemImage: "square.stack.3d.up")
        } else {
            VStack(spacing: 8) {
                Text("未连接 Runtime")
                Text("先用 acro pair <host:port> 完成配对")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func terminalLayoutView(_ node: TerminalLayoutNode) -> AnyView {
        switch node {
        case .leaf(let sessionId):
            return AnyView(terminalPane(sessionId: sessionId))
        case .split(let direction, let first, let second):
            if direction == .horizontal {
                return AnyView(HSplitView {
                    terminalLayoutView(first)
                    terminalLayoutView(second)
                })
            }
            return AnyView(VSplitView {
                terminalLayoutView(first)
                terminalLayoutView(second)
            })
        }
    }

    private func terminalPane(sessionId: String) -> some View {
        let session = activeSessions.first { string($0, "id") == sessionId }
        let focused = currentLayout?.focusedSessionId == sessionId
        let workspaceId = selectedWorkspaceId
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.map(sessionDisplayName) ?? "终端")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let session {
                    Text(URL(fileURLWithPath: string(session, "cwd")).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    focusSessionId(sessionId)
                    splitTerminal(.horizontal)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help("向右分屏")
                .accessibilityLabel("向右分屏")
                Button {
                    focusSessionId(sessionId)
                    splitTerminal(.vertical)
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help("向下分屏")
                .accessibilityLabel("向下分屏")
                Button {
                    if let workspaceId { closePane(workspaceId: workspaceId, sessionId: sessionId) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭窗格")
                .accessibilityLabel("关闭窗格")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(height: focused ? 2 : 1)
            }

            if let session {
                AcroTerminalView(
                    command: AttachCommand.resolve(sessionId: sessionId),
                    focusRequest: focused ? terminalFocusRequest : 0,
                    onClose: {
                        if let workspaceId { closePane(workspaceId: workspaceId, sessionId: sessionId) }
                    },
                    onFocus: { focusSession(session) }
                )
                .id(sessionId)
            } else {
                ContentUnavailableView("终端已结束", systemImage: "terminal")
            }
        }
        .frame(minWidth: 260, minHeight: 220)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
                Text("上下文")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    inspectorVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("隐藏右侧栏")
                .accessibilityLabel("隐藏右侧栏")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let selectedSession {
                        inspectorSection("会话") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sessionDisplayName(selectedSession))
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text("运行中")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            inspectorRow("命令", string(selectedSession, "command"))
                            inspectorRow("目录", string(selectedSession, "cwd"), monospaced: true)

                            HStack(spacing: 8) {
                                Button {
                                    requestTerminalFocus()
                                } label: {
                                    Image(systemName: "text.cursor")
                                }
                                .help("聚焦终端")
                                .accessibilityLabel("聚焦终端")
                                Button(role: .destructive) {
                                    pendingSessionTermination = selectedSession
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .help("关闭终端")
                                .accessibilityLabel("关闭终端")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedProject {
                        inspectorSection("项目") {
                            inspectorRow("名称", string(selectedProject, "name"))
                            inspectorRow("路径", string(selectedProject, "path"), monospaced: true)
                            Button {
                                if let selectedWorkspace {
                                    Task { _ = await openTerminal(project: selectedProject, workspace: selectedWorkspace) }
                                }
                            } label: {
                                Label("新建终端", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedWorkspace {
                        inspectorSection("工作区") {
                            inspectorRow("名称", string(selectedWorkspace, "name"))
                            inspectorRow("项目", "\(strings(selectedWorkspace["projectIds"]).count)")
                            inspectorRow("终端", "\(activeSessionCount(in: selectedWorkspace))")
                        }
                    }

                    inspectorSection("Runtime") {
                        inspectorRow("连接", runtime.connected ? "已连接" : "未连接", valueColor: runtime.connected ? .green : .secondary)
                        inspectorRow("工作区", "\(runtime.workspaces.count)")
                        inspectorRow("运行终端", "\(activeSessions.count)")
                    }
                }
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorRow(
        _ label: String,
        _ value: String,
        valueColor: Color = .secondary,
        monospaced: Bool = false
    ) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func activeSessionCount(in workspace: [String: Any]) -> Int {
        let sessionIds = Set(strings(workspace["sessionIds"]))
        return activeSessions.count { sessionIds.contains(string($0, "id")) }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingWorkspaceDeletion != nil },
            set: { if !$0 { pendingWorkspaceDeletion = nil } }
        )
    }

    private var workspaceGroupRemovalPresented: Binding<Bool> {
        Binding(
            get: { pendingWorkspaceGroupRemoval != nil },
            set: { if !$0 { pendingWorkspaceGroupRemoval = nil } }
        )
    }

    private var projectPickerPresented: Binding<Bool> {
        Binding(
            get: { projectPickerWorkspace != nil },
            set: {
                if !$0 {
                    projectPickerWorkspace = nil
                    projectQuery = ""
                }
            }
        )
    }

    private var terminalProjectPickerPresented: Binding<Bool> {
        Binding(
            get: { terminalProjectPickerWorkspace != nil },
            set: {
                if !$0 {
                    terminalProjectPickerWorkspace = nil
                    projectQuery = ""
                }
            }
        )
    }

    private var terminationPresented: Binding<Bool> {
        Binding(
            get: { pendingSessionTermination != nil },
            set: { if !$0 { pendingSessionTermination = nil } }
        )
    }

    private var projectPicker: some View {
        NavigationStack {
            List {
                ForEach(filteredPickerProjects.indices, id: \.self) { index in
                    let project = filteredPickerProjects[index]
                    Button {
                        if let workspace = projectPickerWorkspace {
                            Task {
                                await addProject(project, to: workspace)
                                projectPickerWorkspace = nil
                                projectQuery = ""
                            }
                        }
                    } label: {
                        Label(string(project, "name"), systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(string(project, "name"))
                }
            }
            .searchable(text: $projectQuery, prompt: "搜索项目")
            .navigationTitle("添加项目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        projectPickerWorkspace = nil
                        projectQuery = ""
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var filteredPickerProjects: [[String: Any]] {
        guard let workspace = projectPickerWorkspace else { return [] }
        let projects = availableProjects(for: workspace)
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            string($0, "name").localizedCaseInsensitiveContains(query)
                || string($0, "path").localizedCaseInsensitiveContains(query)
        }
    }

    private var terminalProjectPicker: some View {
        NavigationStack {
            List {
                ForEach(filteredTerminalProjects.indices, id: \.self) { index in
                    let project = filteredTerminalProjects[index]
                    Button {
                        guard let workspace = terminalProjectPickerWorkspace else { return }
                        terminalProjectPickerWorkspace = nil
                        projectQuery = ""
                        Task { _ = await openTerminal(project: project, workspace: workspace) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(string(project, "name"), systemImage: "folder")
                            Text(string(project, "path"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $projectQuery, prompt: "搜索项目")
            .navigationTitle("新建终端")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        terminalProjectPickerWorkspace = nil
                        projectQuery = ""
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var filteredTerminalProjects: [[String: Any]] {
        guard let workspace = terminalProjectPickerWorkspace else { return [] }
        let values = projects(in: workspace)
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter {
            string($0, "name").localizedCaseInsensitiveContains(query)
                || string($0, "path").localizedCaseInsensitiveContains(query)
        }
    }

    private var commandPaletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                id: "command:new-workspace-group",
                title: "新建分组",
                subtitle: "组织相关工作区",
                symbol: "folder.badge.plus",
                action: { presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "") }
            ),
            CommandPaletteItem(
                id: "command:new-workspace",
                title: "新建工作区",
                subtitle: "创建新的工作上下文",
                symbol: "square.stack.3d.up.badge.plus",
                action: { presentWorkspaceEditor(workspaceId: nil, name: "") }
            ),
            CommandPaletteItem(
                id: "command:toggle-sidebar",
                title: columnVisibility == .detailOnly ? "显示左侧栏" : "隐藏左侧栏",
                subtitle: nil,
                symbol: "sidebar.left",
                action: {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            ),
            CommandPaletteItem(
                id: "command:toggle-inspector",
                title: inspectorVisible ? "隐藏右侧栏" : "显示右侧栏",
                subtitle: nil,
                symbol: "sidebar.right",
                action: { inspectorVisible.toggle() }
            ),
        ]

        if let selectedWorkspace {
            if !projects(in: selectedWorkspace).isEmpty {
                items.append(CommandPaletteItem(
                    id: "command:new-terminal",
                    title: "新建终端",
                    subtitle: string(selectedWorkspace, "name"),
                    symbol: "terminal",
                    action: { requestNewTerminal(in: selectedWorkspace) }
                ))
            }
            if selectedSession != nil, selectedProject != nil {
                items.append(contentsOf: [
                    CommandPaletteItem(
                        id: "command:split-right",
                        title: "向右分屏",
                        subtitle: "在同一项目中创建终端",
                        symbol: "rectangle.split.2x1",
                        action: { splitTerminal(.horizontal) }
                    ),
                    CommandPaletteItem(
                        id: "command:split-down",
                        title: "向下分屏",
                        subtitle: "在同一项目中创建终端",
                        symbol: "rectangle.split.1x2",
                        action: { splitTerminal(.vertical) }
                    ),
                ])
            }
        }

        for workspace in runtime.workspaces {
            let workspaceId = string(workspace, "id")
            items.append(CommandPaletteItem(
                id: "workspace:\(workspaceId)",
                title: string(workspace, "name"),
                subtitle: "工作区 · \(activeSessionCount(in: workspace)) 个运行终端",
                symbol: "square.stack.3d.up",
                action: { selectWorkspace(workspace) }
            ))
            for project in projects(in: workspace) {
                items.append(CommandPaletteItem(
                    id: "project:\(workspaceId):\(string(project, "id"))",
                    title: string(project, "name"),
                    subtitle: "\(string(workspace, "name")) · \(string(project, "path"))",
                    symbol: "folder",
                    action: {
                        Task { _ = await openTerminal(project: project, workspace: workspace) }
                    }
                ))
            }
            for session in sessions(in: workspace) {
                items.append(CommandPaletteItem(
                    id: "session:\(string(session, "id"))",
                    title: sessionDisplayName(session),
                    subtitle: "\(string(workspace, "name")) · \(string(session, "cwd"))",
                    symbol: "terminal",
                    action: { showSession(session) }
                ))
            }
        }
        return items
    }

    private var workspaceIds: [String] {
        runtime.workspaces.map { string($0, "id") }
    }

    private var workspaceGroupIds: [String] {
        runtime.workspaceGroups.map { string($0, "id") }
    }

    private var ungroupedWorkspaces: [[String: Any]] {
        let groupedIds = Set(runtime.workspaceGroups.flatMap { strings($0["workspaceIds"]) })
        return runtime.workspaces.filter { !groupedIds.contains(string($0, "id")) }
    }

    private func workspaces(in group: [String: Any]) -> [[String: Any]] {
        strings(group["workspaceIds"]).compactMap { workspaceId in
            runtime.workspaces.first { string($0, "id") == workspaceId }
        }
    }

    private func workspaceGroup(containing workspaceId: String) -> [String: Any]? {
        runtime.workspaceGroups.first { strings($0["workspaceIds"]).contains(workspaceId) }
    }

    private func projects(in workspace: [String: Any]) -> [[String: Any]] {
        strings(workspace["projectIds"]).compactMap { projectId in
            runtime.projects.first { string($0, "id") == projectId }
        }
    }

    private func availableProjects(for workspace: [String: Any]) -> [[String: Any]] {
        let existing = Set(strings(workspace["projectIds"]))
        return runtime.projects.filter { !existing.contains(string($0, "id")) }
    }

    private func sessions(in workspace: [String: Any]) -> [[String: Any]] {
        let sessionIds = Set(strings(workspace["sessionIds"]))
        return runtime.sessions.filter {
            ($0["alive"] as? Bool ?? false)
                && sessionIds.contains(string($0, "id"))
        }
        .sorted { string($0, "createdAt") < string($1, "createdAt") }
    }

    private func workspaceGroupRow(_ group: [String: Any]) -> some View {
        let groupId = string(group, "id")
        let expanded = expandedWorkspaceGroupIds.contains(groupId)
        let groupWorkspaces = workspaces(in: group)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    toggleWorkspaceGroup(groupId)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "折叠分组" : "展开分组")

                Button {
                    toggleWorkspaceGroup(groupId)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(string(group, "name"))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !groupWorkspaces.isEmpty {
                            Text("\(groupWorkspaces.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(string(group, "name"))
                .accessibilityValue(expanded ? "已展开" : "已折叠")

                Button {
                    presentWorkspaceEditor(
                        workspaceId: nil,
                        name: "",
                        workspaceGroupId: groupId
                    )
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .opacity(hoveredWorkspaceGroupId == groupId ? 1 : 0)
                .allowsHitTesting(hoveredWorkspaceGroupId == groupId)
                .help("在分组中新建工作区")
                .accessibilityLabel("在 \(string(group, "name")) 新建工作区")
            }
            .padding(.horizontal, 6)
            .modifier(SidebarRowSurface(selected: false))
            .onHover { hovering in
                hoveredWorkspaceGroupId = hovering ? groupId : nil
            }
            .contextMenu {
                Button("新建工作区") {
                    presentWorkspaceEditor(
                        workspaceId: nil,
                        name: "",
                        workspaceGroupId: groupId
                    )
                }
                Divider()
                Button("重命名") {
                    presentWorkspaceGroupEditor(
                        workspaceGroupId: groupId,
                        name: string(group, "name")
                    )
                }
                Button("解散分组", role: .destructive) {
                    pendingWorkspaceGroupRemoval = group
                }
            }

            if expanded {
                if groupWorkspaces.isEmpty {
                    Button {
                        presentWorkspaceEditor(
                            workspaceId: nil,
                            name: "",
                            workspaceGroupId: groupId
                        )
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
                    ForEach(groupWorkspaces.indices, id: \.self) { index in
                        workspaceRow(groupWorkspaces[index])
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func workspaceRow(_ workspace: [String: Any]) -> some View {
        let workspaceId = string(workspace, "id")
        let expanded = expandedWorkspaceIds.contains(workspaceId)
        let workspaceProjects = projects(in: workspace)
        let workspaceSessions = sessions(in: workspace)
        let currentGroup = workspaceGroup(containing: workspaceId)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    toggleWorkspace(workspaceId)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "折叠工作区" : "展开工作区")

                Button {
                    selectWorkspace(workspace)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.3.group")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(string(workspace, "name"))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !workspaceSessions.isEmpty {
                            Text("\(workspaceSessions.count)")
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
                .accessibilityLabel(string(workspace, "name"))

                if !workspaceProjects.isEmpty {
                    Button {
                        requestNewTerminal(in: workspace)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .frame(width: 24, height: 24)
                    .buttonStyle(.plain)
                    .opacity(hoveredWorkspaceId == workspaceId ? 1 : 0)
                    .allowsHitTesting(hoveredWorkspaceId == workspaceId)
                    .help("新建终端")
                    .accessibilityLabel("在 \(string(workspace, "name")) 新建终端")
                }
            }
            .padding(.horizontal, 6)
            .modifier(SidebarRowSurface(
                selected: selectedWorkspaceId == workspaceId && selectedSessionId == nil
            ))
            .onHover { hovering in
                hoveredWorkspaceId = hovering ? workspaceId : nil
            }
            .contextMenu {
                if !workspaceProjects.isEmpty {
                    Menu("移除项目") {
                        ForEach(workspaceProjects.indices, id: \.self) { index in
                            let project = workspaceProjects[index]
                            Button(string(project, "name"), role: .destructive) {
                                Task { await removeProject(project, from: workspace) }
                            }
                            .disabled(sessions(in: workspace).contains {
                                string($0, "projectId") == string(project, "id")
                            })
                        }
                    }
                }
                if !runtime.workspaceGroups.isEmpty {
                    Menu("移动到分组") {
                        ForEach(runtime.workspaceGroups.indices, id: \.self) { index in
                            let group = runtime.workspaceGroups[index]
                            Button(string(group, "name")) {
                                Task { await moveWorkspace(workspace, to: group) }
                            }
                            .disabled(string(currentGroup ?? [:], "id") == string(group, "id"))
                        }
                    }
                }
                if currentGroup != nil {
                    Button("移出分组") {
                        Task { await moveWorkspace(workspace, to: nil) }
                    }
                }
                Divider()
                Button("重命名") {
                    presentWorkspaceEditor(
                        workspaceId: workspaceId,
                        name: string(workspace, "name"),
                        workspaceGroupId: nil
                    )
                }
                Button("删除工作区", role: .destructive) {
                    pendingWorkspaceDeletion = workspace
                }
            }
            if expanded {
                if workspaceProjects.isEmpty {
                    Button {
                        selectedWorkspaceId = workspaceId
                        projectPickerWorkspace = workspace
                        projectQuery = ""
                    } label: {
                        Label("添加项目", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                } else {
                    ForEach(workspaceSessions.indices, id: \.self) { index in
                        sessionRow(workspaceSessions[index], workspace: workspace)
                            .padding(.leading, 16)
                    }
                    if workspaceSessions.isEmpty {
                        Button {
                            requestNewTerminal(in: workspace)
                        } label: {
                            Label("新建终端", systemImage: "terminal.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: [String: Any], workspace: [String: Any]) -> some View {
        let alive = session["alive"] as? Bool ?? false
        let sessionId = string(session, "id")
        return Button {
            if alive { showSession(session) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                    .foregroundStyle(selectedSessionId == sessionId ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionDisplayName(session))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(string(session, "cwd"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(alive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarRowSurface(selected: selectedSessionId == sessionId))
        .disabled(!alive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionDisplayName(session))
        .accessibilityValue(alive ? "运行中" : "已结束")
        .contextMenu {
            if let project = project(for: session) {
                Button("在同一项目新建终端") {
                    Task { _ = await openTerminal(project: project, workspace: workspace) }
                }
                Divider()
            }
            Button("关闭终端", role: .destructive) {
                pendingSessionTermination = session
            }
        }
    }

    private func showSession(_ session: [String: Any]) {
        let sessionId = string(session, "id")
        guard let workspace = runtime.workspaces.first(where: {
            strings($0["sessionIds"]).contains(sessionId)
        }) else { return }

        let workspaceId = string(workspace, "id")
        selectedWorkspaceId = workspaceId
        selectedProjectId = string(session, "projectId")
        selectedSessionId = sessionId
        var layout = workspaceLayouts[workspaceId] ?? WorkspaceTerminalLayout()
        if layout.root?.contains(sessionId) == true {
            layout.focusedSessionId = sessionId
        } else if let focusedSessionId = layout.focusedSessionId, layout.root != nil {
            layout.root = layout.root?.replacing(focusedSessionId, with: sessionId)
            layout.focusedSessionId = sessionId
        } else {
            layout = WorkspaceTerminalLayout(root: .leaf(sessionId), focusedSessionId: sessionId)
        }
        workspaceLayouts[workspaceId] = layout
        expandGroupContaining(workspaceId)
        expandedWorkspaceIds.insert(workspaceId)
        requestTerminalFocus()
    }

    private func selectWorkspace(_ workspace: [String: Any]) {
        let workspaceId = string(workspace, "id")
        selectedWorkspaceId = workspaceId
        expandGroupContaining(workspaceId)
        expandedWorkspaceIds.insert(workspaceId)
        if let sessionId = workspaceLayouts[workspaceId]?.focusedSessionId,
           let session = sessions(in: workspace).first(where: { string($0, "id") == sessionId }) {
            showSession(session)
        } else if let session = sessions(in: workspace).first {
            showSession(session)
        } else {
            selectedProjectId = nil
            selectedSessionId = nil
            workspaceLayouts[workspaceId] = WorkspaceTerminalLayout()
        }
    }

    private func focusSession(_ session: [String: Any]) {
        let sessionId = string(session, "id")
        guard let workspace = runtime.workspaces.first(where: {
            strings($0["sessionIds"]).contains(sessionId)
        }) else { return }
        let workspaceId = string(workspace, "id")
        if selectedWorkspaceId != workspaceId { selectedWorkspaceId = workspaceId }
        let projectId = string(session, "projectId")
        if selectedProjectId != projectId { selectedProjectId = projectId }
        if selectedSessionId != sessionId { selectedSessionId = sessionId }
        var layout = workspaceLayouts[workspaceId] ?? WorkspaceTerminalLayout(root: .leaf(sessionId))
        if layout.focusedSessionId != sessionId {
            layout.focusedSessionId = sessionId
            workspaceLayouts[workspaceId] = layout
        }
        if !expandedWorkspaceIds.contains(workspaceId) {
            expandedWorkspaceIds.insert(workspaceId)
        }
        expandGroupContaining(workspaceId)
    }

    private func focusSessionId(_ sessionId: String) {
        guard let session = activeSessions.first(where: { string($0, "id") == sessionId }) else { return }
        focusSession(session)
    }

    private func requestNewTerminal(in workspace: [String: Any]) {
        let workspaceProjects = projects(in: workspace)
        let workspaceId = string(workspace, "id")
        selectedWorkspaceId = workspaceId
        expandGroupContaining(workspaceId)
        expandedWorkspaceIds.insert(workspaceId)
        switch workspaceProjects.count {
        case 0:
            projectPickerWorkspace = workspace
            projectQuery = ""
        case 1:
            Task { _ = await openTerminal(project: workspaceProjects[0], workspace: workspace) }
        default:
            terminalProjectPickerWorkspace = workspace
            projectQuery = ""
        }
    }

    private func splitTerminal(_ direction: TerminalSplitDirection) {
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
            let workspaceId = string(selectedWorkspace, "id")
            let newSessionId = string(session, "id")
            guard var layout = workspaceLayouts[workspaceId],
                  layout.root?.contains(sourceSessionId) == true
            else { return }
            layout.root = layout.root?.splitting(
                sourceSessionId,
                direction: direction,
                newSessionId: newSessionId
            )
            layout.focusedSessionId = newSessionId
            workspaceLayouts[workspaceId] = layout
            if selectedWorkspaceId == workspaceId {
                focusSession(session)
                requestTerminalFocus()
            }
        }
    }

    private func focusAdjacentPane(offset: Int) {
        guard let ids = currentLayout?.root?.sessionIds, ids.count > 1 else { return }
        let currentIndex = ids.firstIndex(of: currentLayout?.focusedSessionId ?? "") ?? 0
        let index = (currentIndex + offset + ids.count) % ids.count
        guard let session = activeSessions.first(where: {
            string($0, "id") == ids[index]
        }) else { return }
        focusSession(session)
        requestTerminalFocus()
    }

    private func closeFocusedPane() {
        guard let workspaceId = selectedWorkspaceId,
              let sessionId = currentLayout?.focusedSessionId
        else { return }
        closePane(workspaceId: workspaceId, sessionId: sessionId)
    }

    private func closePane(workspaceId: String, sessionId: String) {
        guard var layout = workspaceLayouts[workspaceId] else { return }
        layout.remove(sessionId)
        workspaceLayouts[workspaceId] = layout
        guard selectedWorkspaceId == workspaceId else { return }
        guard let focusedSessionId = layout.focusedSessionId else {
            selectedSessionId = nil
            selectedProjectId = nil
            return
        }
        guard let session = activeSessions.first(where: { string($0, "id") == focusedSessionId })
        else {
            selectedSessionId = nil
            selectedProjectId = nil
            return
        }
        guard selectedSessionId != focusedSessionId else { return }
        focusSession(session)
        requestTerminalFocus()
    }

    private func selectAdjacentSession(offset: Int) {
        guard !currentWorkspaceSessions.isEmpty else { return }
        let currentIndex = currentWorkspaceSessions.firstIndex {
            string($0, "id") == selectedSessionId
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + currentWorkspaceSessions.count)
            % currentWorkspaceSessions.count
        showSession(currentWorkspaceSessions[nextIndex])
    }

    private func selectSession(at index: Int) {
        guard currentWorkspaceSessions.indices.contains(index) else { return }
        showSession(currentWorkspaceSessions[index])
    }

    private func requestTerminalFocus() {
        guard selectedSessionId != nil else { return }
        terminalFocusRequest &+= 1
    }

    private func project(for session: [String: Any]) -> [String: Any]? {
        let projectId = string(session, "projectId")
        return runtime.projects.first { string($0, "id") == projectId }
    }

    private func sessionDisplayName(_ session: [String: Any]) -> String {
        let projectName = project(for: session).map { string($0, "name") } ?? "终端"
        let projectId = string(session, "projectId")
        guard let workspace = runtime.workspaces.first(where: {
            strings($0["sessionIds"]).contains(string(session, "id"))
        }) else { return projectName }
        let related = sessions(in: workspace).filter { string($0, "projectId") == projectId }
        guard related.count > 1,
              let index = related.firstIndex(where: { string($0, "id") == string(session, "id") })
        else { return projectName }
        return "\(projectName) · \(index + 1)"
    }

    private func toggleWorkspaceGroup(_ workspaceGroupId: String) {
        if expandedWorkspaceGroupIds.contains(workspaceGroupId) {
            expandedWorkspaceGroupIds.remove(workspaceGroupId)
        } else {
            expandedWorkspaceGroupIds.insert(workspaceGroupId)
        }
    }

    private func toggleWorkspace(_ workspaceId: String) {
        if expandedWorkspaceIds.contains(workspaceId) {
            expandedWorkspaceIds.remove(workspaceId)
        } else {
            expandedWorkspaceIds.insert(workspaceId)
        }
    }

    private func expandGroupContaining(_ workspaceId: String) {
        guard let group = workspaceGroup(containing: workspaceId) else { return }
        expandedWorkspaceGroupIds.insert(string(group, "id"))
    }

    private func presentWorkspaceGroupEditor(workspaceGroupId: String?, name: String) {
        editingWorkspaceGroupId = workspaceGroupId
        workspaceGroupName = name
        showingWorkspaceGroupEditor = true
    }

    private func presentWorkspaceEditor(
        workspaceId: String?,
        name: String,
        workspaceGroupId: String? = nil
    ) {
        editingWorkspaceId = workspaceId
        newWorkspaceGroupId = workspaceId == nil ? workspaceGroupId : nil
        workspaceName = name
        showingWorkspaceEditor = true
    }

    private func saveWorkspaceGroup() async {
        do {
            let name = workspaceGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingWorkspaceGroupId {
                _ = try await runtime.rpc("workspaceGroup.update", [
                    "workspaceGroupId": editingWorkspaceGroupId,
                    "name": name,
                ])
            } else if let group = try await runtime.rpc(
                "workspaceGroup.create",
                ["name": name]
            ) as? [String: Any] {
                expandedWorkspaceGroupIds.insert(string(group, "id"))
            }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveWorkspace() async {
        do {
            let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingWorkspaceId {
                _ = try await runtime.rpc("workspace.update", [
                    "workspaceId": editingWorkspaceId,
                    "name": name,
                ])
            } else {
                var params: [String: Any] = ["name": name]
                if let newWorkspaceGroupId {
                    params["workspaceGroupId"] = newWorkspaceGroupId
                }
                guard let workspace = try await runtime.rpc("workspace.create", params)
                    as? [String: Any]
                else { return }
                let workspaceId = string(workspace, "id")
                if let newWorkspaceGroupId {
                    expandedWorkspaceGroupIds.insert(newWorkspaceGroupId)
                }
                expandedWorkspaceIds.insert(workspaceId)
                selectedWorkspaceId = workspaceId
                selectedProjectId = nil
                selectedSessionId = nil
            }
            newWorkspaceGroupId = nil
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addProject(_ project: [String: Any], to workspace: [String: Any]) async {
        do {
            var projectIds = strings(workspace["projectIds"])
            projectIds.append(string(project, "id"))
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": string(workspace, "id"),
                "projectIds": projectIds,
            ])
            selectedWorkspaceId = string(workspace, "id")
            selectedProjectId = string(project, "id")
            selectedSessionId = nil
            expandedWorkspaceIds.insert(string(workspace, "id"))
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeProject(_ project: [String: Any], from workspace: [String: Any]) async {
        do {
            let projectId = string(project, "id")
            let projectIds = strings(workspace["projectIds"]).filter { $0 != projectId }
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": string(workspace, "id"),
                "projectIds": projectIds,
            ])
            if selectedWorkspaceId == string(workspace, "id"), selectedProjectId == projectId {
                selectedProjectId = nil
                selectedSessionId = nil
            }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveWorkspace(
        _ workspace: [String: Any],
        to group: [String: Any]?
    ) async {
        do {
            let groupId = group.map { string($0, "id") }
            _ = try await runtime.rpc("workspace.update", [
                "workspaceId": string(workspace, "id"),
                "workspaceGroupId": groupId ?? NSNull(),
            ])
            if let groupId { expandedWorkspaceGroupIds.insert(groupId) }
            await runtime.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeWorkspaceGroup(_ group: [String: Any]) async {
        do {
            let groupId = string(group, "id")
            _ = try await runtime.rpc("workspaceGroup.remove", [
                "workspaceGroupId": groupId,
            ])
            expandedWorkspaceGroupIds.remove(groupId)
            pendingWorkspaceGroupRemoval = nil
            await runtime.refresh()
        } catch {
            pendingWorkspaceGroupRemoval = nil
            errorMessage = error.localizedDescription
        }
    }

    private func deleteWorkspace(_ workspace: [String: Any]) async {
        do {
            let workspaceId = string(workspace, "id")
            _ = try await runtime.rpc("workspace.remove", [
                "workspaceId": workspaceId,
            ])
            workspaceLayouts.removeValue(forKey: workspaceId)
            expandedWorkspaceIds.remove(workspaceId)
            if selectedWorkspaceId == workspaceId {
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

    @discardableResult
    private func openTerminal(
        project: [String: Any],
        workspace: [String: Any],
        activate: Bool = true
    ) async -> [String: Any]? {
        do {
            if let session = try await runtime.rpc("session.create", [
                "workspaceId": string(workspace, "id"),
                "projectId": string(project, "id"),
                "cols": 140,
                "rows": 40,
            ]) as? [String: Any] {
                await runtime.refresh()
                if activate { showSession(session) }
                return session
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }

    private func terminateSession(_ session: [String: Any]) async {
        do {
            let sessionId = string(session, "id")
            let workspaceId = runtime.workspaces.first(where: {
                strings($0["sessionIds"]).contains(sessionId)
            }).map { string($0, "id") }
            _ = try await runtime.rpc("session.kill", ["sessionId": sessionId])
            pendingSessionTermination = nil
            await runtime.refresh()
            if let workspaceId, var layout = workspaceLayouts[workspaceId] {
                layout.remove(sessionId)
                workspaceLayouts[workspaceId] = layout
                if selectedWorkspaceId == workspaceId {
                    if let focusedSessionId = layout.focusedSessionId,
                       let focusedSession = activeSessions.first(where: {
                           string($0, "id") == focusedSessionId
                       }) {
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

    private func restoreLayoutIfNeeded() {
        guard !layoutRestored else { return }
        layoutRestored = true
        guard let data = persistedLayout.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data)
        else { return }
        selectedWorkspaceId = snapshot.selectedWorkspaceId
        workspaceLayouts = snapshot.workspaceLayouts
        columnVisibility = snapshot.leftSidebarVisible ? .all : .detailOnly
        inspectorVisible = snapshot.inspectorVisible
    }

    private func reconcileLayoutState() {
        guard runtime.snapshotLoaded else { return }
        let validWorkspaceGroupIds = Set(workspaceGroupIds)
        if workspaceGroupsInitialized {
            expandedWorkspaceGroupIds.formIntersection(validWorkspaceGroupIds)
        } else {
            workspaceGroupsInitialized = true
            expandedWorkspaceGroupIds = validWorkspaceGroupIds
        }
        let validWorkspaceIds = Set(workspaceIds)
        expandedWorkspaceIds.formIntersection(validWorkspaceIds)
        workspaceLayouts = workspaceLayouts.filter { validWorkspaceIds.contains($0.key) }

        for workspace in runtime.workspaces {
            let workspaceId = string(workspace, "id")
            let workspaceSessions = sessions(in: workspace)
            let validSessionIds = Set(workspaceSessions.map { string($0, "id") })
            if var layout = workspaceLayouts[workspaceId] {
                layout.prune(validSessionIds: validSessionIds)
                workspaceLayouts[workspaceId] = layout
            } else if let firstSessionId = workspaceSessions.first.map({ string($0, "id") }) {
                workspaceLayouts[workspaceId] = WorkspaceTerminalLayout(
                    root: .leaf(firstSessionId),
                    focusedSessionId: firstSessionId
                )
            } else {
                workspaceLayouts[workspaceId] = WorkspaceTerminalLayout()
            }
        }

        if let selectedWorkspaceId, !validWorkspaceIds.contains(selectedWorkspaceId) {
            self.selectedWorkspaceId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = runtime.workspaces.first.map { string($0, "id") }
        }
        guard let selectedWorkspaceId else {
            selectedProjectId = nil
            selectedSessionId = nil
            return
        }
        expandedWorkspaceIds.insert(selectedWorkspaceId)
        expandGroupContaining(selectedWorkspaceId)
        guard let focusedSessionId = workspaceLayouts[selectedWorkspaceId]?.focusedSessionId,
              let focusedSession = activeSessions.first(where: {
                  string($0, "id") == focusedSessionId
              })
        else {
            selectedProjectId = nil
            selectedSessionId = nil
            return
        }
        selectedSessionId = focusedSessionId
        selectedProjectId = string(focusedSession, "projectId")
    }

    private func persistLayout() {
        guard layoutRestored else { return }
        let snapshot = WorkbenchLayoutSnapshot(
            selectedWorkspaceId: selectedWorkspaceId,
            workspaceLayouts: workspaceLayouts,
            leftSidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: inspectorVisible
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        persistedLayout = String(decoding: data, as: UTF8.self)
    }

    private func string(_ value: [String: Any], _ key: String) -> String {
        value[key] as? String ?? ""
    }

    private func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

private struct SidebarRowSurface: ViewModifier {
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
