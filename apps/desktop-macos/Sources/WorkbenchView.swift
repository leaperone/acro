// 工作台主容器:侧边栏 + 终端窗格 + 右侧栏 + 命令面板浮层 + 重连横幅。

import SwiftUI

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.leftSidebarVisible ? .all : .detailOnly },
            set: { model.leftSidebarVisible = $0 != .detailOnly }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView(columnVisibility: columnVisibility) {
                SidebarView(model: model, runtime: runtime)
            } detail: {
                GeometryReader { geometry in
                    HSplitView {
                        TerminalPanesView(model: model, runtime: runtime)
                            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)

                        if model.inspectorVisible, geometry.size.width >= 720 {
                            InspectorView(model: model, runtime: runtime)
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .leading
                    )
                }
                .navigationTitle(model.windowTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showingCommandPalette = true
                        } label: {
                            Image(systemName: "command")
                        }
                        .help("命令面板")
                        .accessibilityLabel("命令面板")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.inspectorVisible.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(model.inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                        .accessibilityLabel(model.inspectorVisible ? "隐藏右侧栏" : "显示右侧栏")
                    }
                }
            }

            reconnectBanner

            if model.showingCommandPalette {
                CommandPalette(items: model.commandPaletteItems) {
                    model.showingCommandPalette = false
                    model.requestTerminalFocus()
                }
                .zIndex(10)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .onChange(of: runtime.snapshotLoaded, initial: true) { _, loaded in
            guard loaded else { return }
            let shouldFocusTerminal = !model.layoutWasRestored
            model.restoreLayoutIfNeeded()
            model.reconcileLayoutState()
            if shouldFocusTerminal {
                DispatchQueue.main.async { model.requestTerminalFocus() }
            }
        }
        .onChange(of: runtime.snapshotRevision) { _, _ in
            guard runtime.snapshotLoaded, model.layoutWasRestored else { return }
            model.reconcileLayoutState()
        }
        .alert(
            model.editingWorkspaceGroupId == nil ? "新建分组" : "重命名分组",
            isPresented: $model.showingWorkspaceGroupEditor
        ) {
            TextField("名称", text: $model.workspaceGroupName)
            Button("取消", role: .cancel) {}
            Button(model.editingWorkspaceGroupId == nil ? "创建" : "保存") {
                Task { await model.saveWorkspaceGroup() }
            }
            .disabled(
                model.workspaceGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .alert("重命名工作区", isPresented: $model.showingWorkspaceEditor) {
            TextField("名称", text: $model.workspaceName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task { await model.saveWorkspaceName() }
            }
            .disabled(model.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .confirmationDialog("删除工作区？", isPresented: deletionPresented) {
            Button("删除", role: .destructive) {
                if let workspace = model.pendingWorkspaceDeletion {
                    Task { await model.deleteWorkspace(workspace) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行中的会话会阻止删除。")
        }
        .confirmationDialog("解散分组？", isPresented: groupRemovalPresented) {
            Button("解散", role: .destructive) {
                if let group = model.pendingWorkspaceGroupRemoval {
                    Task { await model.removeWorkspaceGroup(group) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("工作区会保留，并移到未分组区域。")
        }
        .confirmationDialog("关闭终端？", isPresented: terminationPresented) {
            Button("关闭", role: .destructive) {
                if let session = model.pendingSessionTermination {
                    Task { await model.terminateSession(session) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("终端中的运行进程会被结束。")
        }
        .sheet(isPresented: projectPickerPresented) {
            ProjectDirectoryPicker(model: model)
        }
        .sheet(isPresented: terminalProjectPickerPresented) {
            TerminalProjectPicker(model: model)
        }
        .focusedSceneValue(\.workbenchActions, workbenchActions)
    }

    // 断线时置顶提示;探针判死后由指数退避自动重连
    @ViewBuilder
    private var reconnectBanner: some View {
        if runtime.snapshotLoaded && !runtime.connected {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    runtime.reconnectAttempt > 1
                        ? "连接已断开，正在重连（第 \(runtime.reconnectAttempt) 次）…"
                        : "连接已断开，正在重连…"
                )
                .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(5)
            .animation(.easeOut(duration: 0.2), value: runtime.state)
        }
    }

    private var workbenchActions: WorkbenchActions {
        WorkbenchActions(
            newWorkspaceGroup: {
                model.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "")
            },
            newWorkspace: { Task { await model.createWorkspace() } },
            newTerminalTab: {
                if let workspace = model.selectedWorkspace {
                    model.requestNewTerminal(in: workspace)
                }
            },
            showCommandPalette: { model.showingCommandPalette = true },
            splitRight: { model.splitTerminal(.horizontal) },
            splitDown: { model.splitTerminal(.vertical) },
            focusPreviousPane: { model.focusAdjacentPane(offset: -1) },
            focusNextPane: { model.focusAdjacentPane(offset: 1) },
            closeTab: { model.closeFocusedTab() },
            toggleLeftSidebar: { model.leftSidebarVisible.toggle() },
            toggleInspector: { model.inspectorVisible.toggle() },
            previousTab: { model.selectAdjacentTab(offset: -1) },
            nextTab: { model.selectAdjacentTab(offset: 1) },
            selectWorkspaceAtIndex: { model.selectWorkspace(at: $0) },
            focusTerminal: { model.requestTerminalFocus() },
            killSession: {
                if let session = model.selectedSession {
                    model.pendingSessionTermination = session
                }
            },
            canCreateTerminal: model.selectedWorkspace.map { !model.projects(in: $0).isEmpty } ?? false,
            canSplitTerminal: model.selectedWorkspace != nil
                && model.selectedProject != nil
                && model.selectedSession != nil,
            canNavigatePanes: model.currentLayout?.root?.panes.count ?? 0 > 1,
            canCloseTab: model.currentLayout?.focusedSessionId != nil,
            canNavigateTabs: model.currentLayout?.focusedPane?.sessionIds.count ?? 0 > 1,
            canFocusTerminal: model.selectedSession != nil,
            canKillSession: model.selectedSession != nil,
            workspaceCount: model.orderedWorkspaces.count,
            leftSidebarVisible: model.leftSidebarVisible,
            inspectorVisible: model.inspectorVisible
        )
    }

    // ---- Binding 包装 ----

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { model.pendingWorkspaceDeletion != nil },
            set: { if !$0 { model.pendingWorkspaceDeletion = nil } }
        )
    }

    private var groupRemovalPresented: Binding<Bool> {
        Binding(
            get: { model.pendingWorkspaceGroupRemoval != nil },
            set: { if !$0 { model.pendingWorkspaceGroupRemoval = nil } }
        )
    }

    private var terminationPresented: Binding<Bool> {
        Binding(
            get: { model.pendingSessionTermination != nil },
            set: { if !$0 { model.pendingSessionTermination = nil } }
        )
    }

    private var projectPickerPresented: Binding<Bool> {
        Binding(
            get: { model.projectPickerWorkspace != nil },
            set: {
                if !$0 {
                    model.projectPickerWorkspace = nil
                    model.resetProjectPicker()
                }
            }
        )
    }

    private var terminalProjectPickerPresented: Binding<Bool> {
        Binding(
            get: { model.terminalProjectPickerWorkspace != nil },
            set: {
                if !$0 {
                    model.terminalProjectPickerWorkspace = nil
                    model.projectQuery = ""
                }
            }
        )
    }
}
