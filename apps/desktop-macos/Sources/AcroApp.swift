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
    let toggleLeftSidebar: () -> Void
    let toggleInspector: () -> Void
    let previousSession: () -> Void
    let nextSession: () -> Void
    let focusTerminal: () -> Void
    let closeSession: () -> Void
    let canCreateTerminal: Bool
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
            Button(actions?.leftSidebarVisible == true ? "隐藏左侧栏" : "显示左侧栏", systemImage: "sidebar.left") {
                actions?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button(actions?.inspectorVisible == true ? "隐藏右侧栏" : "显示右侧栏", systemImage: "sidebar.right") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

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
        let node = env["ACRO_NODE"]
            ?? ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "node"
        let cli = env["ACRO_CLI_PATH"]
            ?? "\(NSHomeDirectory())/project/acro/apps/cli/src/cli.ts"
        return "\(node) \(cli) attach \(sessionId)"
    }
}

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeConnection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = true
    @State private var selectedWorkspaceId: String?
    @State private var selectedProjectId: String?
    @State private var selectedSessionId: String?
    @State private var terminalFocusRequest = 0
    @State private var expandedWorkspaceIds: Set<String> = []
    @State private var knownWorkspaceIds: Set<String> = []
    @State private var showingWorkspaceEditor = false
    @State private var editingWorkspaceId: String?
    @State private var workspaceName = ""
    @State private var pendingWorkspaceDeletion: [String: Any]?
    @State private var pendingSessionTermination: [String: Any]?
    @State private var projectPickerWorkspace: [String: Any]?
    @State private var projectQuery = ""
    @State private var errorMessage: String?

    var body: some View {
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
                expandedWorkspaceIds.formUnion(current.subtracting(knownWorkspaceIds))
                expandedWorkspaceIds.formIntersection(current)
                knownWorkspaceIds = current
                if let selectedWorkspaceId, !current.contains(selectedWorkspaceId) {
                    self.selectedWorkspaceId = nil
                    selectedProjectId = nil
                    selectedSessionId = nil
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
                        inspectorVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                    .accessibilityLabel(inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                }
            }
        }
        .frame(minHeight: 620)
        .onChange(of: activeSessionIds) { _, ids in
            if let selectedSessionId, !ids.contains(selectedSessionId) {
                self.selectedSessionId = nil
            }
            if self.selectedSessionId == nil, let session = activeSessions.first {
                selectSession(session)
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
        .focusedSceneValue(\.workbenchActions, workbenchActions)
    }

    private var workbenchActions: WorkbenchActions {
        WorkbenchActions(
            newWorkspace: { presentWorkspaceEditor(workspaceId: nil, name: "") },
            newTerminal: { createTerminalFromSelection() },
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
            canCreateTerminal: selectedWorkspace != nil && selectedProject != nil,
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
        if let sessionId = selectedSessionId {
            AcroTerminalView(
                command: AttachCommand.resolve(sessionId: sessionId),
                focusRequest: terminalFocusRequest,
                onClose: { selectedSessionId = nil }
            )
            .id(sessionId)
        } else if selectedWorkspace != nil, selectedProject != nil {
            ContentUnavailableView {
                Label("没有终端", systemImage: "terminal")
            } actions: {
                Button("新建终端") {
                    createTerminalFromSelection()
                }
            }
        } else if runtime.connected {
            ContentUnavailableView("选择项目", systemImage: "folder")
        } else {
            VStack(spacing: 8) {
                Text("未连接 Runtime")
                Text("先用 acro pair <host:port> 完成配对")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                                createTerminalFromSelection()
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

    private func sessions(in workspace: [String: Any], projectId: String) -> [[String: Any]] {
        let sessionIds = Set(strings(workspace["sessionIds"]))
        return runtime.sessions.filter {
            ($0["alive"] as? Bool ?? false)
                && sessionIds.contains(string($0, "id"))
                && string($0, "projectId") == projectId
        }
    }

    private func workspaceRow(_ workspace: [String: Any]) -> some View {
        let workspaceId = string(workspace, "id")
        let expanded = expandedWorkspaceIds.contains(workspaceId)
        let workspaceProjects = projects(in: workspace)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    selectedWorkspaceId = workspaceId
                    selectedProjectId = nil
                    selectedSessionId = nil
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
                        Label(string(workspace, "name"), systemImage: "square.stack.3d.up")
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        selectedWorkspaceId == workspaceId && selectedProjectId == nil
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(string(workspace, "name"))
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                Spacer()
                Button("添加项目", systemImage: "plus") {
                    selectedWorkspaceId = workspaceId
                    projectPickerWorkspace = workspace
                    projectQuery = ""
                }
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
                .buttonStyle(.borderless)
                .disabled(availableProjects(for: workspace).isEmpty)
                .help("添加项目")
                .accessibilityLabel("添加项目")
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
                        .padding(.leading, 28)
                } else {
                    ForEach(workspaceProjects.indices, id: \.self) { index in
                        projectRow(workspaceProjects[index], workspace: workspace)
                            .padding(.leading, 18)
                    }
                }
            }
        }
        .contextMenu {
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

    private func projectRow(_ project: [String: Any], workspace: [String: Any]) -> some View {
        let projectId = string(project, "id")
        let projectSessions = sessions(in: workspace, projectId: projectId)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    selectProject(project, workspace: workspace)
                } label: {
                    Label(string(project, "name"), systemImage: "folder")
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            selectedWorkspaceId == string(workspace, "id")
                                && selectedProjectId == projectId
                                && selectedSessionId == nil
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("新建终端", systemImage: "plus") {
                    selectProject(project, workspace: workspace)
                    Task { await openTerminal(project: project, workspace: workspace) }
                }
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
                .buttonStyle(.borderless)
                .help("新建终端")
                .accessibilityLabel("在 \(string(project, "name")) 新建终端")
            }
            ForEach(projectSessions.indices, id: \.self) { index in
                sessionRow(projectSessions[index])
                    .padding(.leading, 18)
            }
            if projectSessions.isEmpty {
                Button {
                    selectProject(project, workspace: workspace)
                    Task { await openTerminal(project: project, workspace: workspace) }
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            }
        }
        .contextMenu {
            Button("从工作区移除", role: .destructive) {
                Task { await removeProject(project, from: workspace) }
            }
        }
    }

    private func sessionRow(_ session: [String: Any]) -> some View {
        let alive = session["alive"] as? Bool ?? false
        let sessionId = string(session, "id")
        return Button {
            if alive { selectSession(session) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(alive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(string(session, "command"))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                selectedSessionId == sessionId ? Color.accentColor.opacity(0.16) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!alive)
        .accessibilityLabel(string(session, "command"))
        .accessibilityValue(alive ? "运行中" : "已结束")
        .contextMenu {
            Button("关闭终端", role: .destructive) {
                pendingSessionTermination = session
            }
        }
    }

    private func selectProject(_ project: [String: Any], workspace: [String: Any]) {
        selectedWorkspaceId = string(workspace, "id")
        selectedProjectId = string(project, "id")
        selectedSessionId = nil
        expandedWorkspaceIds.insert(string(workspace, "id"))
    }

    private func selectSession(_ session: [String: Any]) {
        let sessionId = string(session, "id")
        guard let workspace = runtime.workspaces.first(where: {
            strings($0["sessionIds"]).contains(sessionId)
        }) else { return }

        selectedWorkspaceId = string(workspace, "id")
        selectedProjectId = string(session, "projectId")
        selectedSessionId = sessionId
        expandedWorkspaceIds.insert(string(workspace, "id"))
        requestTerminalFocus()
    }

    private func createTerminalFromSelection() {
        guard let selectedWorkspace, let selectedProject else { return }
        Task { await openTerminal(project: selectedProject, workspace: selectedWorkspace) }
    }

    private func selectAdjacentSession(offset: Int) {
        guard !activeSessions.isEmpty else { return }
        let currentIndex = activeSessions.firstIndex {
            string($0, "id") == selectedSessionId
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + activeSessions.count) % activeSessions.count
        selectSession(activeSessions[nextIndex])
    }

    private func requestTerminalFocus() {
        guard selectedSessionId != nil else { return }
        terminalFocusRequest &+= 1
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

    private func openTerminal(project: [String: Any], workspace: [String: Any]) async {
        do {
            if let session = try await runtime.rpc("session.create", [
                "workspaceId": string(workspace, "id"),
                "projectId": string(project, "id"),
                "cols": 140,
                "rows": 40,
            ]) as? [String: Any] {
                await runtime.refresh()
                selectSession(session)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
            if wasSelected {
                if let fallbackSession {
                    selectSession(fallbackSession)
                } else {
                    selectedSessionId = nil
                }
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
