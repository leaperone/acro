// 工作台主容器:侧边栏 + 终端窗格 + 右侧栏 + 命令面板浮层 + 重连横幅。

import SwiftUI

enum WorkbenchLayoutMetrics {
    static let minimumWindowWidth: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 620
    static let minimumTerminalWidth: CGFloat = 440
    static let inspectorVisibilityWidth: CGFloat = 720
    static let minimumInspectorWidth: CGFloat = 260
    static let defaultSidebarWidth: CGFloat = 248
    static let minimumSidebarWidth: CGFloat = 180
    static let maximumSidebarWidth: CGFloat = 420
}

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFullScreen = false
    // 自绘布局(cmux 模式):NavigationSplitView 会给隐藏的工具栏保留整条高度,
    // 紧凑模式必须让 tab 条真正贴到窗口顶边。
    @AppStorage("acro.sidebar.width") private var sidebarWidth = Double(
        WorkbenchLayoutMetrics.defaultSidebarWidth
    )
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.leftSidebarPresentation == .wide {
                    SidebarView(model: model, hub: model.hub)
                        .frame(width: max(
                            WorkbenchLayoutMetrics.minimumSidebarWidth,
                            min(CGFloat(sidebarWidth), WorkbenchLayoutMetrics.maximumSidebarWidth)
                        ))
                        .transition(.opacity)
                    sidebarResizeHandle
                } else if model.leftSidebarPresentation == .compact {
                    CompactSidebarView(model: model, hub: model.hub)
                        .transition(.opacity)
                }

                GeometryReader { geometry in
                    // HSplitView(NSSplitView)会给子视图重新套顶部安全区,逐层穿透
                    HSplitView {
                        TerminalPanesView(
                            model: model,
                            runtime: runtime,
                            tabBarLeadingInsetOverride: isFullScreen ? 0 : nil
                        )
                            .ignoresSafeArea(.container, edges: .top)
                            .frame(
                                minWidth: WorkbenchLayoutMetrics.minimumTerminalWidth,
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                            .background(
                                model.terminalChromeAppearance.usesSharedBackdrop
                                    ? Color(nsColor: model.terminalChromeAppearance.backgroundColor)
                                    : Color.clear
                            )
                            .layoutPriority(1)

                        if model.inspectorVisible,
                           geometry.size.width >= WorkbenchLayoutMetrics.inspectorVisibilityWidth {
                            RightSidebarView(model: model, runtime: runtime)
                                .ignoresSafeArea(.container, edges: .top)
                                .frame(
                                    minWidth: WorkbenchLayoutMetrics.minimumInspectorWidth,
                                    idealWidth: 320,
                                    maxWidth: 460
                                )
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
            .background(WindowConfigurator { isFullScreen in
                self.isFullScreen = isFullScreen
            })
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: model.leftSidebarPresentation
            )

            reconnectBanner

            if model.showingCommandPalette {
                CommandPalette(items: model.commandPaletteItems) {
                    model.showingCommandPalette = false
                    model.requestTerminalFocus()
                }
                .zIndex(10)
            }
        }
        .frame(
            minWidth: WorkbenchLayoutMetrics.minimumWindowWidth,
            minHeight: WorkbenchLayoutMetrics.minimumWindowHeight
        )
        .onChange(of: runtime.snapshotLoaded, initial: true) { _, loaded in
            guard loaded else { return }
            model.handleSnapshotLoaded()
        }
        .onChange(of: runtime.snapshotRevision) { _, _ in
            guard runtime.snapshotLoaded, model.layoutWasRestored else { return }
            model.scheduleReconcile()
        }
        .onChange(of: runtime.state) { _, state in
            if state != .connected { model.resetStartupWorkspaceSelection() }
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
                if let request = model.takePendingSessionTerminationRequest() {
                    Task { await model.confirmSessionTermination(request) }
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
        if !runtime.connected, runtime.recoveryState != .idle {
            HStack(spacing: 8) {
                if runtime.recoveryState == .retrying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(
                    runtime.recoveryState == .configurationError
                        ? (runtime.lastConnectionError ?? "")
                        : runtime.lastConnectionError.map { "\($0),正在重连…" }
                            ?? (runtime.reconnectAttempt > 1
                                ? "连接已断开，正在重连（第 \(runtime.reconnectAttempt) 次）…"
                                : "连接已断开，正在重连…")
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
                                sidebarWidth = Double(min(
                                    max(
                                        value.location.x,
                                        WorkbenchLayoutMetrics.minimumSidebarWidth
                                    ),
                                    WorkbenchLayoutMetrics.maximumSidebarWidth
                                ))
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
            get: { model.pendingSessionTerminationRequest != nil },
            set: {
                if !$0 { model.cancelPendingSessionTermination() }
            }
        )
    }

}

// 顶栏空位的显式窗口拖动(cmux TitlebarAccessoryContainerView 语义)。
// 窗口平时保持 isMovable=false；这里只在原生拖动事务期间临时开放移动。
// 单击拖动,双击执行系统缩放
final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private static let dragStartDistanceSquared: CGFloat = 16
    private var pendingDragEvent: NSEvent?
    private var pendingDragStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            clearPendingDrag()
            window.zoom(nil)
            return
        }
        pendingDragEvent = event
        pendingDragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pendingDragEvent, let pendingDragStart else { return }
        let dx = event.locationInWindow.x - pendingDragStart.x
        let dy = event.locationInWindow.y - pendingDragStart.y
        guard dx * dx + dy * dy >= Self.dragStartDistanceSquared else { return }

        clearPendingDrag()
        let wasMovable = window.isMovable
        window.isMovable = true
        defer { window.isMovable = wasMovable }
        window.performDrag(with: pendingDragEvent)
    }

    override func mouseUp(with event: NSEvent) {
        clearPendingDrag()
    }

    private func clearPendingDrag() {
        pendingDragEvent = nil
        pendingDragStart = nil
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
final class WindowConfigurationView: NSView {
    var onFullScreenChange: (Bool) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        onFullScreenChange(window.styleMask.contains(.fullScreen))
        configure(window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryChanged),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFullScreenChanged),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFullScreenChanged),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        scheduleConfiguration()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func scheduleConfiguration() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.configure(window)
        }
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        scheduleConfiguration()
    }

    @objc private func windowFullScreenChanged(_ notification: Notification) {
        onFullScreenChange(notification.name == NSWindow.didEnterFullScreenNotification)
        scheduleConfiguration()
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.isMovable = false
        cancelHostingSafeArea(in: window)
    }

    private func cancelHostingSafeArea(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        var insets = contentView.additionalSafeAreaInsets
        if window.styleMask.contains(.fullScreen) {
            insets.top = 0
        } else {
            let nativeTitlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
            let unadjustedSafeAreaTop = max(0, contentView.safeAreaInsets.top - insets.top)
            insets.top = -min(nativeTitlebarHeight, unadjustedSafeAreaTop)
        }
        guard abs(contentView.additionalSafeAreaInsets.top - insets.top) > 0.5 else { return }
        contentView.additionalSafeAreaInsets = insets
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowConfigurationView {
        let view = WindowConfigurationView()
        view.onFullScreenChange = onFullScreenChange
        return view
    }

    func updateNSView(_ nsView: WindowConfigurationView, context: Context) {
        nsView.onFullScreenChange = onFullScreenChange
    }
}
