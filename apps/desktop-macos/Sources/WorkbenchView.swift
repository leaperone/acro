// 工作台主容器:侧边栏 + 终端窗格 + 右侧栏 + 命令面板浮层 + 重连横幅。

import SwiftUI

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    @Environment(\.openWindow) private var openWindow
    // 自绘布局(cmux 模式):NavigationSplitView 会给隐藏的工具栏保留整条高度,
    // 紧凑模式必须让 tab 条真正贴到窗口顶边。
    @AppStorage("acro.sidebar.width") private var sidebarWidth = 248.0

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.leftSidebarVisible {
                    SidebarView(model: model, runtime: runtime, hub: model.hub)
                        .frame(width: max(180, min(sidebarWidth, 420)))
                    sidebarResizeHandle
                }

                GeometryReader { geometry in
                    // HSplitView(NSSplitView)会给子视图重新套顶部安全区,逐层穿透
                    HSplitView {
                        TerminalPanesView(model: model, runtime: runtime)
                            .ignoresSafeArea(.container, edges: .top)
                            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)

                        if model.inspectorVisible, geometry.size.width >= 720 {
                            InspectorView(model: model, runtime: runtime)
                                .ignoresSafeArea(.container, edges: .top)
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .leading
                    )
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .coordinateSpace(name: "workbench-root")
            .ignoresSafeArea(.container, edges: .top)
            .background(WindowConfigurator())
            .animation(.easeOut(duration: 0.18), value: model.leftSidebarVisible)

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
            model.handleSnapshotLoaded()
        }
        .onChange(of: runtime.snapshotRevision) { _, _ in
            guard runtime.snapshotLoaded, model.layoutWasRestored else { return }
            model.scheduleReconcile()
        }
        .onChange(of: model.hub.entries.map(\.id), initial: true) { _, _ in
            model.scheduleReconcile()
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
        .confirmationDialog(
            model.pendingWorkspaceDeletionSessionCount > 0 ? "删除工作区和终端？" : "删除工作区？",
            isPresented: deletionPresented
        ) {
            Button(
                model.pendingWorkspaceDeletionSessionCount > 0 ? "关闭终端并删除" : "删除",
                role: .destructive
            ) {
                if let workspace = model.pendingWorkspaceDeletion {
                    Task { await model.deleteWorkspace(workspace) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if model.pendingWorkspaceDeletionSessionCount > 0 {
                Text(
                    "这个工作区还有 \(model.pendingWorkspaceDeletionSessionCount) 个活跃终端会话。继续会结束其中运行的进程，关闭全部终端，并删除工作区。此操作无法撤销。"
                )
            } else {
                Text("此操作无法撤销。")
            }
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
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text("终端中的运行进程会被结束。")
        }
        .confirmationDialog("重启终端服务？", isPresented: $model.showingDaemonRestartConfirmation) {
            Button(
                model.pendingDaemonRestartSessionCount > 0 ? "关闭终端并重启" : "重启",
                role: .destructive
            ) {
                Task { await model.restartTerminalDaemon() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if model.pendingDaemonRestartSessionCount > 0 {
                Text(
                    "当前服务器有 \(model.pendingDaemonRestartSessionCount) 个活跃终端。继续会结束其中运行的进程，重启终端服务，并自动创建一个新终端。"
                )
            } else {
                Text("将重启当前服务器的终端服务，并自动创建一个新终端。")
            }
        }
        .onChange(of: model.settingsOpenRequest) { _, _ in
            openWindow(id: "settings")
        }
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

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("workbench-root"))
                            .onChanged { value in
                                sidebarWidth = Double(min(max(value.location.x, 180), 420))
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
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

}

// 顶栏空位的显式窗口拖动(cmux TitlebarAccessoryContainerView 语义):
// 窗口 isMovable=false(见 WindowConfigurator),这里手动移动窗口——
// performDrag 在 isMovable=false 下是 no-op,必须自己跟踪拖拽。
// 单击拖动,双击执行系统缩放
final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private var dragOrigin: (window: NSPoint, mouse: NSPoint)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            window.zoom(nil)
            return
        }
        dragOrigin = (window.frame.origin, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragOrigin.window.x + (mouse.x - dragOrigin.mouse.x),
            y: dragOrigin.window.y + (mouse.y - dragOrigin.mouse.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

// 无标题栏窗口:内容全幅。
// isMovable=false 是"窗口拖动只走 WindowDragHandle"的硬保证:
// 标题栏带的隐式拖动看的是"被命中的最深层 NSView"的 mouseDownCanMoveWindow,
// 标签条内嵌的 NSScrollView(SwiftUI ScrollView 桥接)内部视图会返回可拖,
// 容器级覆盖挡不住;直接关掉窗口级隐式移动才是根治。
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
