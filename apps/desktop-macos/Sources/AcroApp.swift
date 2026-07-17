// Acro Desktop:工作区侧边栏 + libghostty 终端表面。
// 终端渲染由 libghostty 完成,surface command 跑 `acro attach <sessionId>`,
// 会话本体永远活在 Runtime 侧的 terminal daemon 里。

import AppKit
import SwiftUI

final class AcroAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct WorkbenchActions {
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
    let focusTerminal: () -> Void
    let closeSession: () -> Void
    let canCreateTerminal: Bool
    let canSplitTerminal: Bool
    let canNavigatePanes: Bool
    let canClosePane: Bool
    let canNavigateSessions: Bool
    let canFocusTerminal: Bool
    let canCloseSession: Bool
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

private enum TerminalSplit: Equatable {
    case horizontal
    case vertical
}

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeConnection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = false
    @State private var selectedWorkspaceId: String?
    @State private var selectedProjectId: String?
    @State private var selectedSessionId: String?
    @State private var paneSessionIds: [String] = []
    @State private var focusedPaneIndex = 0
    @State private var terminalSplit: TerminalSplit?
    @State private var terminalFocusRequest = 0
    @State private var expandedWorkspaceIds: Set<String> = []
    @State private var showingWorkspaceEditor = false
    @State private var editingWorkspaceId: String?
    @State private var workspaceName = ""
    @State private var pendingWorkspaceDeletion: [String: Any]?
    @State private var pendingSessionTermination: [String: Any]?
    @State private var projectPickerWorkspace: [String: Any]?
    @State private var terminalProjectPickerWorkspace: [String: Any]?
    @State private var projectQuery = ""
    @State private var showingCommandPalette = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("工作区")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    if runtime.workspaces.isEmpty {
                        Button {
                            presentWorkspaceEditor(workspaceId: nil, name: "")
                        } label: {
                            Label("新建工作区", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(runtime.workspaces.indices, id: \.self) { index in
                            workspaceRow(runtime.workspaces[index])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(.bar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .onChange(of: workspaceIds, initial: true) { _, ids in
                let current = Set(ids)
                expandedWorkspaceIds.formIntersection(current)
                if let selectedWorkspaceId, !current.contains(selectedWorkspaceId) {
                    self.selectedWorkspaceId = nil
                    selectedProjectId = nil
                    selectedSessionId = nil
                }
                if self.selectedWorkspaceId == nil,
                   let first = runtime.workspaces.first {
                    let workspaceId = string(first, "id")
                    self.selectedWorkspaceId = workspaceId
                    expandedWorkspaceIds.insert(workspaceId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentWorkspaceEditor(workspaceId: nil, name: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("新建工作区")
                    .accessibilityLabel("新建工作区")
                }
            }
            } detail: {
                HSplitView {
                    terminalContent
                        .frame(minWidth: 440, maxHeight: .infinity)
                        .layoutPriority(1)

                    if inspectorVisible {
                        inspector
                            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                            .frame(maxHeight: .infinity)
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
        .onChange(of: activeSessionIds) { _, ids in
            paneSessionIds = paneSessionIds.filter(ids.contains)
            if paneSessionIds.count < 2 { terminalSplit = nil }
            focusedPaneIndex = min(focusedPaneIndex, max(paneSessionIds.count - 1, 0))
            if let selectedSessionId, !ids.contains(selectedSessionId) {
                self.selectedSessionId = nil
            }
            if self.selectedSessionId == nil {
                if let paneId = paneSessionIds.first,
                   let session = activeSessions.first(where: { string($0, "id") == paneId }) {
                    focusSession(session, paneIndex: 0)
                } else if let session = activeSessions.first {
                    showSession(session)
                }
            }
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

    private var workbenchActions: WorkbenchActions {
        WorkbenchActions(
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
            focusTerminal: { requestTerminalFocus() },
            closeSession: {
                if let selectedSession { pendingSessionTermination = selectedSession }
            },
            canCreateTerminal: selectedWorkspace.map { !projects(in: $0).isEmpty } ?? false,
            canSplitTerminal: selectedWorkspace != nil && selectedProject != nil && selectedSession != nil,
            canNavigatePanes: paneSessionIds.count > 1,
            canClosePane: !paneSessionIds.isEmpty,
            canNavigateSessions: activeSessions.count > 1,
            canFocusTerminal: selectedSession != nil,
            canCloseSession: selectedSession != nil,
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
        if terminalSplit == .horizontal, paneSessionIds.count == 2 {
            HSplitView {
                terminalPane(sessionId: paneSessionIds[0], paneIndex: 0)
                terminalPane(sessionId: paneSessionIds[1], paneIndex: 1)
            }
        } else if terminalSplit == .vertical, paneSessionIds.count == 2 {
            VSplitView {
                terminalPane(sessionId: paneSessionIds[0], paneIndex: 0)
                terminalPane(sessionId: paneSessionIds[1], paneIndex: 1)
            }
        } else if let sessionId = paneSessionIds.first ?? selectedSessionId {
            terminalPane(sessionId: sessionId, paneIndex: 0)
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

    private func terminalPane(sessionId: String, paneIndex: Int) -> some View {
        let session = activeSessions.first { string($0, "id") == sessionId }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(session.map(sessionDisplayName) ?? "终端")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let session {
                    Text(URL(fileURLWithPath: string(session, "cwd")).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    splitTerminal(.horizontal)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help("向右分屏")
                .accessibilityLabel("向右分屏")
                Button {
                    splitTerminal(.vertical)
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help("向下分屏")
                .accessibilityLabel("向下分屏")
                Button {
                    closePane(at: paneIndex)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭窗格")
                .accessibilityLabel("关闭窗格")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(paneIndex == focusedPaneIndex ? Color.accentColor.opacity(0.1) : Color.clear)

            Divider()

            if let session {
                AcroTerminalView(
                    command: AttachCommand.resolve(sessionId: sessionId),
                    focusRequest: paneIndex == focusedPaneIndex ? terminalFocusRequest : 0,
                    onClose: { closePane(at: paneIndex) },
                    onFocus: { focusSession(session, paneIndex: paneIndex) }
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
                Text("上下文")
                    .font(.headline)
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
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let selectedSession {
                        inspectorSection("会话") {
                            inspectorRow("状态", "运行中", valueColor: .green)
                            inspectorRow("命令", string(selectedSession, "command"))
                            inspectorRow("目录", string(selectedSession, "cwd"), monospaced: true)

                            HStack(spacing: 8) {
                                Button("聚焦终端", systemImage: "text.cursor") {
                                    requestTerminalFocus()
                                }
                                Button("关闭", systemImage: "xmark", role: .destructive) {
                                    pendingSessionTermination = selectedSession
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedProject {
                        inspectorSection("项目") {
                            inspectorRow("名称", string(selectedProject, "name"))
                            inspectorRow("路径", string(selectedProject, "path"), monospaced: true)
                            Button("新建终端", systemImage: "plus") {
                                if let selectedWorkspace {
                                    Task { _ = await openTerminal(project: selectedProject, workspace: selectedWorkspace) }
                                }
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
                id: "command:new-workspace",
                title: "新建工作区",
                subtitle: "创建新的任务分组",
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

    private func workspaceRow(_ workspace: [String: Any]) -> some View {
        let workspaceId = string(workspace, "id")
        let expanded = expandedWorkspaceIds.contains(workspaceId)
        let workspaceProjects = projects(in: workspace)
        let workspaceSessions = sessions(in: workspace)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    selectWorkspace(workspace)
                    if expanded {
                        expandedWorkspaceIds.remove(workspaceId)
                    } else {
                        expandedWorkspaceIds.insert(workspaceId)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 10)
                        Image(systemName: "square.stack.3d.up")
                            .frame(width: 16)
                        Text(string(workspace, "name"))
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
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(
                        selectedWorkspaceId == workspaceId
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(string(workspace, "name"))
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                if !workspaceProjects.isEmpty {
                    Button {
                        requestNewTerminal(in: workspace)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .frame(width: 24, height: 24)
                    .buttonStyle(.borderless)
                    .help("新建终端")
                    .accessibilityLabel("在 \(string(workspace, "name")) 新建终端")
                }
            }
            if expanded {
                if workspaceProjects.isEmpty {
                    Button {
                        selectedWorkspaceId = workspaceId
                        projectPickerWorkspace = workspace
                        projectQuery = ""
                    } label: {
                        Label("添加项目", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                } else {
                    ForEach(workspaceSessions.indices, id: \.self) { index in
                        sessionRow(workspaceSessions[index], workspace: workspace)
                            .padding(.leading, 18)
                    }
                    if workspaceSessions.isEmpty {
                        Text("尚无运行终端")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 42)
                            .frame(height: 28)
                    }
                    HStack(spacing: 14) {
                        Button {
                            requestNewTerminal(in: workspace)
                        } label: {
                            Label("新建终端", systemImage: "plus")
                        }
                        Button {
                            projectPickerWorkspace = workspace
                            projectQuery = ""
                        } label: {
                            Label("添加项目", systemImage: "folder.badge.plus")
                        }
                        .disabled(availableProjects(for: workspace).isEmpty)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
                    .frame(height: 30)
                }
            }
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
            Button("重命名") {
                presentWorkspaceEditor(
                    workspaceId: workspaceId,
                    name: string(workspace, "name")
                )
            }
            Button("删除工作区", role: .destructive) {
                pendingWorkspaceDeletion = workspace
            }
        }
    }

    private func sessionRow(_ session: [String: Any], workspace: [String: Any]) -> some View {
        let alive = session["alive"] as? Bool ?? false
        let sessionId = string(session, "id")
        return Button {
            if alive { showSession(session) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(alive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionDisplayName(session))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(string(session, "command"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                selectedSessionId == sessionId ? Color.accentColor.opacity(0.22) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!alive)
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

        selectedWorkspaceId = string(workspace, "id")
        selectedProjectId = string(session, "projectId")
        selectedSessionId = sessionId
        if let paneIndex = paneSessionIds.firstIndex(of: sessionId) {
            focusedPaneIndex = paneIndex
        } else if terminalSplit != nil, paneSessionIds.count == 2 {
            paneSessionIds[focusedPaneIndex] = sessionId
        } else {
            paneSessionIds = [sessionId]
            focusedPaneIndex = 0
            terminalSplit = nil
        }
        expandedWorkspaceIds.insert(string(workspace, "id"))
        requestTerminalFocus()
    }

    private func selectWorkspace(_ workspace: [String: Any]) {
        let workspaceId = string(workspace, "id")
        selectedWorkspaceId = workspaceId
        expandedWorkspaceIds.insert(workspaceId)
        if let selectedSessionId,
           strings(workspace["sessionIds"]).contains(selectedSessionId) {
            return
        }
        if let session = sessions(in: workspace).first {
            showSession(session)
        } else {
            selectedProjectId = nil
            selectedSessionId = nil
            paneSessionIds = []
            focusedPaneIndex = 0
            terminalSplit = nil
        }
    }

    private func focusSession(_ session: [String: Any], paneIndex: Int) {
        let sessionId = string(session, "id")
        guard let workspace = runtime.workspaces.first(where: {
            strings($0["sessionIds"]).contains(sessionId)
        }) else { return }
        selectedWorkspaceId = string(workspace, "id")
        selectedProjectId = string(session, "projectId")
        selectedSessionId = sessionId
        focusedPaneIndex = paneIndex
        expandedWorkspaceIds.insert(string(workspace, "id"))
    }

    private func requestNewTerminal(in workspace: [String: Any]) {
        let workspaceProjects = projects(in: workspace)
        selectedWorkspaceId = string(workspace, "id")
        expandedWorkspaceIds.insert(string(workspace, "id"))
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

    private func splitTerminal(_ direction: TerminalSplit) {
        if paneSessionIds.count == 2 {
            terminalSplit = direction
            requestTerminalFocus()
            return
        }
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
            paneSessionIds = [sourceSessionId, string(session, "id")]
            terminalSplit = direction
            focusSession(session, paneIndex: 1)
            requestTerminalFocus()
        }
    }

    private func focusAdjacentPane(offset: Int) {
        guard paneSessionIds.count > 1 else { return }
        let index = (focusedPaneIndex + offset + paneSessionIds.count) % paneSessionIds.count
        guard let session = activeSessions.first(where: {
            string($0, "id") == paneSessionIds[index]
        }) else { return }
        focusSession(session, paneIndex: index)
        requestTerminalFocus()
    }

    private func closeFocusedPane() {
        closePane(at: focusedPaneIndex)
    }

    private func closePane(at index: Int) {
        guard paneSessionIds.indices.contains(index) else { return }
        paneSessionIds.remove(at: index)
        terminalSplit = nil
        focusedPaneIndex = 0
        guard !paneSessionIds.isEmpty else {
            selectedSessionId = nil
            return
        }
        guard let sessionId = paneSessionIds.first,
              let session = activeSessions.first(where: { string($0, "id") == sessionId })
        else {
            selectedSessionId = nil
            return
        }
        focusSession(session, paneIndex: 0)
        requestTerminalFocus()
    }

    private func selectAdjacentSession(offset: Int) {
        guard !activeSessions.isEmpty else { return }
        let currentIndex = activeSessions.firstIndex {
            string($0, "id") == selectedSessionId
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + activeSessions.count) % activeSessions.count
        showSession(activeSessions[nextIndex])
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

    private func presentWorkspaceEditor(workspaceId: String?, name: String) {
        editingWorkspaceId = workspaceId
        workspaceName = name
        showingWorkspaceEditor = true
    }

    private func saveWorkspace() async {
        do {
            let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingWorkspaceId {
                _ = try await runtime.rpc("workspace.update", [
                    "workspaceId": editingWorkspaceId,
                    "name": name,
                ])
            } else if let workspace = try await runtime.rpc(
                "workspace.create",
                ["name": name]
            ) as? [String: Any] {
                let workspaceId = string(workspace, "id")
                expandedWorkspaceIds.insert(workspaceId)
                selectedWorkspaceId = workspaceId
                selectedProjectId = nil
                selectedSessionId = nil
            }
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

    private func deleteWorkspace(_ workspace: [String: Any]) async {
        do {
            let sessionIds = Set(strings(workspace["sessionIds"]))
            _ = try await runtime.rpc("workspace.remove", [
                "workspaceId": string(workspace, "id"),
            ])
            if let selectedSessionId, sessionIds.contains(selectedSessionId) {
                self.selectedSessionId = nil
            }
            paneSessionIds.removeAll { sessionIds.contains($0) }
            if paneSessionIds.count < 2 { terminalSplit = nil }
            if selectedWorkspaceId == string(workspace, "id") {
                selectedWorkspaceId = nil
                selectedProjectId = nil
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
            let wasSelected = selectedSessionId == sessionId
            let fallbackSession: [String: Any]?
            if wasSelected,
               let currentIndex = activeSessions.firstIndex(where: { string($0, "id") == sessionId }) {
                let remainingSessions = activeSessions.filter { string($0, "id") != sessionId }
                fallbackSession = remainingSessions.isEmpty
                    ? nil
                    : remainingSessions[min(currentIndex, remainingSessions.count - 1)]
            } else {
                fallbackSession = nil
            }
            _ = try await runtime.rpc("session.kill", ["sessionId": sessionId])
            pendingSessionTermination = nil
            await runtime.refresh()
            let removedPaneIndex = paneSessionIds.firstIndex(of: sessionId)
            paneSessionIds.removeAll { $0 == sessionId }
            if paneSessionIds.count < 2 { terminalSplit = nil }
            if wasSelected {
                if let paneId = paneSessionIds.first,
                   let paneSession = activeSessions.first(where: { string($0, "id") == paneId }) {
                    focusSession(paneSession, paneIndex: 0)
                    requestTerminalFocus()
                } else if let fallbackSession {
                    showSession(fallbackSession)
                } else {
                    selectedSessionId = nil
                }
            } else if let removedPaneIndex {
                focusedPaneIndex = min(removedPaneIndex, max(paneSessionIds.count - 1, 0))
            }
        } catch {
            pendingSessionTermination = nil
            errorMessage = error.localizedDescription
        }
    }

    private func string(_ value: [String: Any], _ key: String) -> String {
        value[key] as? String ?? ""
    }

    private func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
