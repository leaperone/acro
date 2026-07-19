// 终端窗格区:分屏树渲染 + 窗格顶部标签条 + 拖拽移动/分屏 + 注意力闪环。
// 标签条与拖拽交互对标 cmux 的 Bonsplit 窗格标签组
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.)。

import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let acroTabTransfer = UTType(
        exportedAs: "one.leaper.acro.tab-transfer",
        conformingTo: .data
    )
}

// 拖到窗格身上的落点区域:沿用 Bonsplit 的 25% / 最少 80pt 边缘分屏区。
enum PaneDropZone: Equatable {
    case center
    case left, right, top, bottom

    static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let horizontalEdge = max(80, size.width * 0.25)
        let verticalEdge = max(80, size.height * 0.25)
        if point.x < horizontalEdge { return .left }
        if point.x > size.width - horizontalEdge { return .right }
        if point.y < verticalEdge { return .top }
        if point.y > size.height - verticalEdge { return .bottom }
        return .center
    }

    var direction: TerminalSplitDirection? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    var newPaneFirst: Bool {
        self == .left || self == .top
    }

    func highlightRect(in size: CGSize) -> CGRect {
        let padding: CGFloat = 4
        switch self {
        case .center:
            return CGRect(
                x: padding,
                y: padding,
                width: max(0, size.width - padding * 2),
                height: max(0, size.height - padding * 2)
            )
        case .left:
            return CGRect(
                x: padding,
                y: padding,
                width: max(0, size.width / 2 - padding),
                height: max(0, size.height - padding * 2)
            )
        case .right:
            return CGRect(
                x: size.width / 2,
                y: padding,
                width: max(0, size.width / 2 - padding),
                height: max(0, size.height - padding * 2)
            )
        case .top:
            return CGRect(
                x: padding,
                y: padding,
                width: max(0, size.width - padding * 2),
                height: max(0, size.height / 2 - padding)
            )
        case .bottom:
            return CGRect(
                x: padding,
                y: size.height / 2,
                width: max(0, size.width - padding * 2),
                height: max(0, size.height / 2 - padding)
            )
        }
    }
}

struct TerminalPanesView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        if let root = model.currentLayout?.root {
            layoutView(root, isTopLeft: true)
        } else if let selectedWorkspace = model.selectedWorkspace {
            ContentUnavailableView {
                Label("没有终端", systemImage: "terminal")
            } actions: {
                Button("新建终端") {
                    model.requestNewTerminal(in: selectedWorkspace)
                }
            }
        } else if runtime.connected {
            ContentUnavailableView("选择工作区", systemImage: "square.stack.3d.up")
        } else {
            VStack(spacing: 8) {
                Text("未连接 Runtime")
                Text("在设置(⌘,)里粘贴配对码,或在 Runtime 本机运行 acro pair")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // isTopLeft 沿 first 链传递:只有贴住窗口左上角的窗格需要给红绿灯让位
    private func layoutView(_ node: TerminalLayoutNode, isTopLeft: Bool = false) -> AnyView {
        switch node {
        case .pane(let group):
            return AnyView(PaneView(model: model, pane: group, isTopLeft: isTopLeft))
        case .split(let splitNode):
            return AnyView(RatioSplitView(
                node: splitNode,
                content: { child in
                    layoutView(child, isTopLeft: isTopLeft && child == splitNode.first)
                },
                onRatioChange: { ratio in
                    guard let splitId = UUID(uuidString: splitNode.id) else { return }
                    model.setSplitRatio(splitId, ratio: ratio)
                }
            ))
        }
    }
}

// ---- 比例分屏容器:ratio 持久化在布局树,分隔线可拖(几何算法来自 CmuxPanes) ----

private struct RatioSplitView: View {
    let node: SplitNode
    let content: (TerminalLayoutNode) -> AnyView
    let onRatioChange: (Double) -> Void

    // 布局只让出 1pt(cmux 级细缝);拖拽命中区悬浮在两侧窗格上,不占空间
    private static let dividerThickness: CGFloat = 1
    private static let dividerHitThickness: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let horizontal = node.direction == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let firstLength = max(
                0, total * node.ratio - Self.dividerThickness / 2
            )
            let secondLength = max(0, total - firstLength - Self.dividerThickness)
            Group {
                if horizontal {
                    HStack(spacing: 0) {
                        content(node.first)
                            .frame(width: firstLength)
                        divider(horizontal: true, total: total)
                        content(node.second)
                            .frame(width: secondLength)
                    }
                } else {
                    VStack(spacing: 0) {
                        content(node.first)
                            .frame(height: firstLength)
                        divider(horizontal: false, total: total)
                        content(node.second)
                            .frame(height: secondLength)
                    }
                }
            }
            .coordinateSpace(name: "split-\(node.id)")
        }
    }

    private func divider(horizontal: Bool, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: horizontal ? Self.dividerThickness : nil,
                height: horizontal ? nil : Self.dividerThickness
            )
            .overlay(
                Color.clear
                    .frame(
                        width: horizontal ? Self.dividerHitThickness : nil,
                        height: horizontal ? nil : Self.dividerHitThickness
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("split-\(node.id)"))
                            .onChanged { value in
                                guard total > 0 else { return }
                                let position = horizontal ? value.location.x : value.location.y
                                onRatioChange(Double(position / total))
                            }
                    )
            )
            .zIndex(1)
    }
}

// ---- 单个窗格:标签条 + 常驻终端叠层 + 拖拽落点 ----

private struct PaneView: View {
    @ObservedObject var model: WorkbenchModel
    let pane: PaneTabGroup
    var isTopLeft = false
    @State private var dropZone: PaneDropZone?

    private var focused: Bool {
        model.currentLayout?.focusedPane?.id == pane.id
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar(
                model: model,
                pane: pane,
                focused: focused,
                trafficLightClearance: isTopLeft && !model.leftSidebarVisible
            )

            GeometryReader { geometry in
                ZStack {
                    // 标签常驻:切换零延迟,后台 TUI 持续渲染(cmux 保活 surface 的做法)
                    ForEach(pane.sessionIds, id: \.self) { sessionId in
                        terminal(sessionId: sessionId)
                            .opacity(pane.selectedSessionId == sessionId ? 1 : 0)
                            .allowsHitTesting(
                                model.draggingTab == nil && pane.selectedSessionId == sessionId
                            )
                    }
                    if pane.sessionIds.isEmpty {
                        ContentUnavailableView("终端已结束", systemImage: "terminal")
                    }

                    // 常驻 drop layer:内嵌 AppKit 终端会抢走容器级拖拽目标。
                    // Bonsplit 同样把透明 drop layer 放在内容最上层。
                    Color.clear
                        .onDrop(
                            of: [.acroTabTransfer],
                            delegate: PaneBodyDropDelegate(
                                size: { geometry.size },
                                zone: Binding(get: { dropZone }, set: { dropZone = $0 }),
                                canAccept: {
                                    guard let payload = model.draggingTab,
                                          model.validDrag(payload) else {
                                        return false
                                    }
                                    return !(payload.sourcePaneId == pane.id
                                        && pane.sessionIds == [payload.sessionId])
                                },
                                perform: { zone in
                                    guard let payload = model.draggingTab else { return false }
                                    model.draggingTab = nil
                                    if let direction = zone.direction {
                                        model.moveTabToSplit(
                                            payload,
                                            ofPane: pane.id,
                                            direction: direction,
                                            newPaneFirst: zone.newPaneFirst
                                        )
                                    } else {
                                        model.moveTab(payload, toPane: pane.id, at: nil)
                                    }
                                    return true
                                }
                            )
                        )

                    if let dropZone {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                            .frame(
                                width: dropZone.highlightRect(in: geometry.size).width,
                                height: dropZone.highlightRect(in: geometry.size).height
                            )
                            .position(
                                x: dropZone.highlightRect(in: geometry.size).midX,
                                y: dropZone.highlightRect(in: geometry.size).midY
                            )
                            .allowsHitTesting(false)
                            .animation(.spring(duration: 0.25, bounce: 0.15), value: dropZone)
                    }
                }
            }
        }
        // 不设 minWidth/minHeight:RatioSplitView 用定长 frame 排版,
        // min 约束会顶破分配空间、盖到相邻窗格上;窗格下限由 ratio clamp(0.1)保证
        .attentionFlash(
            token: model.flashToken,
            active: pane.sessionIds.contains(model.flashSessionId ?? "")
        )
    }

    @ViewBuilder
    private func terminal(sessionId: String) -> some View {
        if let serverId = model.selectedServerId,
           let workspaceId = model.selectedWorkspaceId,
           model.session(sessionId) != nil {
            ZStack {
                AcroTerminalView(
                    serverId: serverId,
                    sessionId: sessionId,
                    command: AttachCommand.resolve(
                        sessionId: sessionId, serverId: serverId),
                    focusRequest: focused && pane.selectedSessionId == sessionId
                        ? model.terminalFocusRequest
                        : 0,
                    onClose: {
                        model.closeTab(
                            sessionId,
                            workspaceId: workspaceId,
                            serverId: serverId
                        )
                    },
                    onFocus: { model.selectTab(sessionId, inPane: pane.id) }
                )
                .id(ScopedResourceID(serverId: serverId, resourceId: sessionId))

                // 占用蒙版:他端正在使用,内容遮住、交互挡掉,必须显式接管
                if let occupant = model.focusOccupant(sessionId) {
                    FocusLockOverlay(
                        deviceName: occupant.deviceName,
                        takeOver: { model.claimFocus(sessionId, force: true) }
                    )
                }
            }
        } else {
            ContentUnavailableView("终端已结束", systemImage: "terminal")
        }
    }
}

// ---- 标签条 ----

private struct PaneTabBar: View {
    @ObservedObject var model: WorkbenchModel
    let pane: PaneTabGroup
    let focused: Bool
    var trafficLightClearance = false

    var body: some View {
        // 窗口级 isMovable=false 已根治标题栏带拖窗,标签条留在主 hosting view;
        // 嵌套 NSHostingView 会破坏 .onDrag 的拖拽会话,不要再包一层
        tabBarContent
            .onDrop(
                of: [.acroTabTransfer],
                delegate: TabBarDropDelegate(
                    canAccept: { model.validDrag(model.draggingTab) },
                    perform: {
                        guard let payload = model.draggingTab else { return false }
                        model.draggingTab = nil
                        // 标签条空白 = 显式"排到末尾";nil(反悔语义)留给窗格 body 中心区
                        model.moveTab(payload, toPane: pane.id, at: pane.sessionIds.count)
                        return true
                    }
                )
            )
            .frame(height: 28)
            .background {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.bar)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                }
            }
    }

    private var tabBarContent: some View {
        HStack(spacing: 0) {
            if trafficLightClearance {
                WindowDragHandle()
                    .frame(width: 80)
                    .frame(maxHeight: .infinity)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pane.sessionIds.enumerated()), id: \.element) { index, sessionId in
                        tab(sessionId: sessionId, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity)

            Button {
                if let workspace = model.selectedWorkspace {
                    model.requestNewTerminal(in: workspace, paneId: pane.id)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建标签(\(ShortcutSettings.stored(.newTerminalTab).displayString))")
            .accessibilityLabel("新建标签")
            .padding(.trailing, 4)
        }
    }

    private func tab(sessionId: String, index: Int) -> some View {
        let selected = pane.selectedSessionId == sessionId
        let session = model.session(sessionId)
        return PaneTabItem(
            title: session.map { model.sessionDisplayName($0) } ?? "终端",
            selected: selected,
            focused: focused,
            shortcutHint: model.controlHeld && focused
                ? model.tabShortcutDigit(sessionId, inPane: pane.id).map { "⌃\($0)" }
                : nil,
            select: { model.selectTab(sessionId, inPane: pane.id) },
            kill: { model.requestKillTab(sessionId) },
            // 分屏基于焦点窗格:先把该标签选中再分,语义与 orca 的"非激活标签先激活"一致
            splitRight: {
                model.selectTab(sessionId, inPane: pane.id)
                model.splitTerminal(.horizontal)
            },
            splitDown: {
                model.selectTab(sessionId, inPane: pane.id)
                model.splitTerminal(.vertical)
            },
            beginDrag: {
                let payload = TabDragPayload(sessionId: sessionId, sourcePaneId: pane.id)
                model.draggingTab = payload
                let provider = TabDragItemProvider()
                let data = Data(sessionId.utf8)
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.acroTabTransfer.identifier,
                    visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
                provider.onEnd = { Task { @MainActor in model.endTabDrag(payload) } }
                return provider
            },
            acceptDrop: {
                model.validDrag(model.draggingTab) && model.draggingTab?.sessionId != sessionId
            },
            performDrop: {
                guard let payload = model.draggingTab else { return false }
                model.draggingTab = nil
                model.moveTab(payload, toPane: pane.id, at: index)
                return true
            }
        )
    }
}

// 单个标签。快照边界之下:只收值 + 闭包,不持 store。
private struct PaneTabItem: View {
    let title: String
    let selected: Bool
    let focused: Bool
    let shortcutHint: String?
    let select: () -> Void
    let kill: () -> Void
    let splitRight: () -> Void
    let splitDown: () -> Void
    let beginDrag: () -> NSItemProvider
    let acceptDrop: () -> Bool
    let performDrop: () -> Bool

    @State private var hovered = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11))
                .foregroundStyle(selected ? .primary : .secondary)

            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)

            ZStack {
                if let shortcutHint {
                    ShortcutHintPill(text: shortcutHint, fontSize: 8)
                } else if selected || hovered {
                    Button(action: kill) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭标签(终止终端)")
                    .accessibilityLabel("关闭标签 \(title)")
                }
            }
            .frame(width: 28, height: 20)
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 48, maxWidth: 220, minHeight: 28, maxHeight: 28)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            selected
                ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                : hovered
                    ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    : AnyShapeStyle(Color.clear)
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.bottom, selected ? 1 : 0)
        }
        .overlay(alignment: .top) {
            if selected {
                Rectangle()
                    .fill(Color.accentColor)
                    .saturation(focused ? 1 : 0)
                    .frame(height: 1.5)
                    .padding(.trailing, 1)
            }
        }
        .overlay(alignment: .leading) {
            if dropTargeted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 20)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("向右分屏(\(ShortcutSettings.stored(.splitRight).displayString))", action: splitRight)
            Button("向下分屏(\(ShortcutSettings.stored(.splitDown).displayString))", action: splitDown)
            Divider()
            Button("关闭标签(终止终端)", role: .destructive, action: kill)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onDrag(beginDrag)
        .onDrop(
            of: [.acroTabTransfer],
            delegate: TabInsertDropDelegate(
                isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 }),
                canAccept: acceptDrop,
                perform: performDrop
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// 终端占用蒙版:另一台设备正在使用该会话时盖在 surface 上,
// 会话继续在后台接收输出,接管后立即呈现最新状态
private struct FocusLockOverlay: View {
    let deviceName: String
    let takeOver: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            VStack(spacing: 10) {
                Image(systemName: "display.2")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("此终端正在被「\(deviceName)」使用")
                    .font(.callout.weight(.semibold))
                Text("接管后这里恢复操作,对方会被暂停并需要重新接管")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("在此设备继续使用", action: takeOver)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(24)
        }
        .contentShape(Rectangle())
    }
}

// SwiftUI onDrag 没有拖拽会话结束回调;借 NSItemProvider 的生命周期兜底清理。
// 不清的话,ESC 取消/拖出窗口后 draggingTab 残留,会吞掉后续拖进窗格的文本 drop。
private final class TabDragItemProvider: NSItemProvider {
    var onEnd: (() -> Void)?
    deinit { onEnd?() }
}

// ---- Drop delegates(应用内拖拽读 WorkbenchModel 的拖拽真源,不解析 NSItemProvider) ----

private struct TabInsertDropDelegate: DropDelegate {
    let isTargeted: Binding<Bool>
    let canAccept: () -> Bool
    let perform: () -> Bool

    func validateDrop(info: DropInfo) -> Bool { canAccept() }

    func dropEntered(info: DropInfo) {
        if canAccept() { isTargeted.wrappedValue = true }
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        return perform()
    }
}

private struct TabBarDropDelegate: DropDelegate {
    let canAccept: () -> Bool
    let perform: () -> Bool

    func validateDrop(info: DropInfo) -> Bool { canAccept() }
    func performDrop(info: DropInfo) -> Bool { perform() }
}

private struct PaneBodyDropDelegate: DropDelegate {
    let size: () -> CGSize
    let zone: Binding<PaneDropZone?>
    let canAccept: () -> Bool
    let perform: (PaneDropZone) -> Bool

    func validateDrop(info: DropInfo) -> Bool { canAccept() }

    func dropEntered(info: DropInfo) {
        guard canAccept() else { return }
        zone.wrappedValue = PaneDropZone.zone(at: info.location, in: size())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard canAccept() else { return DropProposal(operation: .forbidden) }
        zone.wrappedValue = PaneDropZone.zone(at: info.location, in: size())
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone.wrappedValue = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone.wrappedValue ?? PaneDropZone.zone(at: info.location, in: size())
        zone.wrappedValue = nil
        return perform(target)
    }
}
