// 终端窗格区:分屏树渲染 + 窗格顶部标签条 + 拖拽移动/分屏 + 注意力闪环。
// 标签条与拖拽交互对标 cmux 的 Bonsplit 窗格标签组
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.)。

import SwiftUI
import UniformTypeIdentifiers

// 拖到窗格身上的落点区域:边缘 22% 分屏,中间并入标签组
private enum PaneDropZone: Equatable {
    case center
    case left, right, top, bottom

    static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width
        let y = point.y / size.height
        let edge = 0.22
        if x < edge { return .left }
        if x > 1 - edge { return .right }
        if y < edge { return .top }
        if y > 1 - edge { return .bottom }
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
        switch self {
        case .center: CGRect(origin: .zero, size: size)
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
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
                if model.projects(in: selectedWorkspace).isEmpty {
                    Button("添加项目") {
                        model.presentProjectPicker(for: selectedWorkspace)
                    }
                } else {
                    Button("新建终端") {
                        model.requestNewTerminal(in: selectedWorkspace)
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
                            .allowsHitTesting(pane.selectedSessionId == sessionId)
                    }
                    if pane.sessionIds.isEmpty {
                        ContentUnavailableView("终端已结束", systemImage: "terminal")
                    }

                    if let dropZone {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(
                                Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
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
                    }
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: PaneBodyDropDelegate(
                        size: { geometry.size },
                        zone: Binding(get: { dropZone }, set: { dropZone = $0 }),
                        canAccept: { model.draggingTab != nil },
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
            }
        }
        .frame(minWidth: 280, minHeight: 200)
        .attentionFlash(
            token: model.flashToken,
            active: pane.sessionIds.contains(model.flashSessionId ?? "")
        )
    }

    @ViewBuilder
    private func terminal(sessionId: String) -> some View {
        if model.session(sessionId) != nil {
            AcroTerminalView(
                command: AttachCommand.resolve(sessionId: sessionId),
                focusRequest: focused && pane.selectedSessionId == sessionId
                    ? model.terminalFocusRequest
                    : 0,
                onClose: { model.closeTab(sessionId) },
                onFocus: { model.selectTab(sessionId, inPane: pane.id) }
            )
            .id(sessionId)
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
        HStack(spacing: 4) {
            if trafficLightClearance {
                Color.clear.frame(width: 70)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(Array(pane.sessionIds.enumerated()), id: \.element) { index, sessionId in
                        tab(sessionId: sessionId, index: index)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)

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

            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(focused ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .onDrop(
            of: [UTType.text],
            delegate: TabBarDropDelegate(
                canAccept: { model.draggingTab != nil },
                perform: {
                    guard let payload = model.draggingTab else { return false }
                    model.draggingTab = nil
                    model.moveTab(payload, toPane: pane.id, at: nil)
                    return true
                }
            )
        )
    }

    private func tab(sessionId: String, index: Int) -> some View {
        let selected = pane.selectedSessionId == sessionId
        let session = model.session(sessionId)
        return PaneTabItem(
            title: session.map(model.sessionDisplayName) ?? "终端",
            selected: selected,
            focused: focused,
            select: { model.selectTab(sessionId, inPane: pane.id) },
            kill: { model.requestKillTab(sessionId) },
            beginDrag: {
                model.draggingTab = TabDragPayload(sessionId: sessionId, sourcePaneId: pane.id)
                return NSItemProvider(object: sessionId as NSString)
            },
            acceptDrop: { model.draggingTab != nil && model.draggingTab?.sessionId != sessionId },
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
    let select: () -> Void
    let kill: () -> Void
    let beginDrag: () -> NSItemProvider
    let acceptDrop: () -> Bool
    let performDrop: () -> Bool

    @State private var hovered = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 2) {
            // 选择区域用 Button:mouse-up 触发,不与 onDrag 的 mouse-down 抢事件
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(selected && focused ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: kill) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
            .help("关闭标签(终止终端)")
            .accessibilityLabel("关闭标签 \(title)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: 21)
        .background(
            selected
                ? AnyShapeStyle(Color.primary.opacity(0.08))
                : hovered ? AnyShapeStyle(Color.primary.opacity(0.04)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay(alignment: .leading) {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 18)
                    .offset(x: -2.5)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("关闭标签(终止终端)", role: .destructive, action: kill)
        }
        .onDrag(beginDrag)
        .onDrop(
            of: [UTType.text],
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
