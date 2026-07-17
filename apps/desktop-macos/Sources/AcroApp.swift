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
    @State private var selectedSessionId: String?
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
        NavigationSplitView {
            List {
                Section("工作区") {
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
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .onChange(of: workspaceIds, initial: true) { _, ids in
                let current = Set(ids)
                expandedWorkspaceIds.formUnion(current.subtracting(knownWorkspaceIds))
                expandedWorkspaceIds.formIntersection(current)
                knownWorkspaceIds = current
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
            if let sessionId = selectedSessionId {
                AcroTerminalView(
                    command: AttachCommand.resolve(sessionId: sessionId),
                    onClose: { selectedSessionId = nil }
                )
                .id(sessionId) // 切换会话时重建 surface
            } else if runtime.connected {
                ContentUnavailableView("选择会话", systemImage: "terminal")
            } else {
                VStack(spacing: 8) {
                    Text("未连接 Runtime")
                    Text("先用 acro pair <host:port> 完成配对")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(string(workspace, "name"))
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                Spacer()
                Button("添加项目", systemImage: "plus") {
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
                Label(string(project, "name"), systemImage: "folder")
                    .lineLimit(1)
                Spacer()
                Button("新建终端", systemImage: "plus") {
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
            if alive { selectedSessionId = sessionId }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(alive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(string(session, "command"))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!alive)
        .accessibilityLabel(string(session, "command"))
        .accessibilityValue(alive ? "运行中" : "已结束")
        .listRowBackground(
            selectedSessionId == sessionId ? Color.accentColor.opacity(0.16) : nil
        )
        .contextMenu {
            Button("关闭终端", role: .destructive) {
                pendingSessionTermination = session
            }
        }
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
                expandedWorkspaceIds.insert(string(workspace, "id"))
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
                selectedSessionId = string(session, "id")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func terminateSession(_ session: [String: Any]) async {
        do {
            let sessionId = string(session, "id")
            _ = try await runtime.rpc("session.kill", ["sessionId": sessionId])
            if selectedSessionId == sessionId {
                selectedSessionId = nil
            }
            pendingSessionTermination = nil
            await runtime.refresh()
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
