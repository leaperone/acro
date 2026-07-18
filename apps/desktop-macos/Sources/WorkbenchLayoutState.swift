// 工作区布局树:分屏节点的叶子是"标签组窗格"(cmux/Bonsplit 模型——
// 每个窗格自带一组标签,split 与 tab 同树)。纯值类型,不依赖 UI。

import Foundation

enum TerminalSplitDirection: String, Codable, Equatable {
    case horizontal
    case vertical
}

// 一个窗格 = 一组终端标签 + 当前选中标签
struct PaneTabGroup: Codable, Equatable, Identifiable {
    let id: String
    var sessionIds: [String]
    var selectedSessionId: String?

    init(id: String = UUID().uuidString, sessionIds: [String] = [], selectedSessionId: String? = nil) {
        self.id = id
        self.sessionIds = sessionIds
        self.selectedSessionId = selectedSessionId ?? sessionIds.first
    }

    mutating func appendTab(_ sessionId: String, select: Bool = true) {
        if !sessionIds.contains(sessionId) { sessionIds.append(sessionId) }
        if select { selectedSessionId = sessionId }
    }

    mutating func insertTab(_ sessionId: String, at index: Int, select: Bool = true) {
        sessionIds.removeAll { $0 == sessionId }
        sessionIds.insert(sessionId, at: min(max(index, 0), sessionIds.count))
        if select { selectedSessionId = sessionId }
    }

    // 返回 true 表示窗格已空
    mutating func removeTab(_ sessionId: String) -> Bool {
        guard let index = sessionIds.firstIndex(of: sessionId) else { return sessionIds.isEmpty }
        sessionIds.remove(at: index)
        if selectedSessionId == sessionId {
            selectedSessionId = sessionIds.indices.contains(index)
                ? sessionIds[index]
                : sessionIds.last
        }
        return sessionIds.isEmpty
    }

    mutating func keepValidTabs(_ validSessionIds: Set<String>) -> Bool {
        sessionIds.removeAll { !validSessionIds.contains($0) }
        if let selectedSessionId, !sessionIds.contains(selectedSessionId) {
            self.selectedSessionId = sessionIds.first
        }
        if selectedSessionId == nil { selectedSessionId = sessionIds.first }
        return sessionIds.isEmpty
    }
}

indirect enum TerminalLayoutNode: Codable, Equatable {
    case pane(PaneTabGroup)
    case split(
        direction: TerminalSplitDirection,
        first: TerminalLayoutNode,
        second: TerminalLayoutNode
    )

    var panes: [PaneTabGroup] {
        switch self {
        case .pane(let group):
            [group]
        case .split(_, let first, let second):
            first.panes + second.panes
        }
    }

    var sessionIds: [String] {
        panes.flatMap(\.sessionIds)
    }

    func pane(withId paneId: String) -> PaneTabGroup? {
        panes.first { $0.id == paneId }
    }

    func paneContaining(_ sessionId: String) -> PaneTabGroup? {
        panes.first { $0.sessionIds.contains(sessionId) }
    }

    func updatingPane(_ paneId: String, transform: (inout PaneTabGroup) -> Void) -> TerminalLayoutNode {
        switch self {
        case .pane(var group):
            guard group.id == paneId else { return self }
            transform(&group)
            return .pane(group)
        case .split(let direction, let first, let second):
            return .split(
                direction: direction,
                first: first.updatingPane(paneId, transform: transform),
                second: second.updatingPane(paneId, transform: transform)
            )
        }
    }

    // 在指定窗格处分屏;newPaneFirst 控制新窗格在前半(左/上)还是后半(右/下)
    func splitting(
        paneId: String,
        direction: TerminalSplitDirection,
        newPane: PaneTabGroup,
        newPaneFirst: Bool = false
    ) -> TerminalLayoutNode {
        switch self {
        case .pane(let group):
            guard group.id == paneId else { return self }
            return newPaneFirst
                ? .split(direction: direction, first: .pane(newPane), second: self)
                : .split(direction: direction, first: self, second: .pane(newPane))
        case .split(let currentDirection, let first, let second):
            return .split(
                direction: currentDirection,
                first: first.splitting(
                    paneId: paneId, direction: direction, newPane: newPane, newPaneFirst: newPaneFirst
                ),
                second: second.splitting(
                    paneId: paneId, direction: direction, newPane: newPane, newPaneFirst: newPaneFirst
                )
            )
        }
    }

    // 摘掉空窗格;整棵树空则返回 nil
    func compacted() -> TerminalLayoutNode? {
        switch self {
        case .pane(let group):
            return group.sessionIds.isEmpty ? nil : self
        case .split(let direction, let first, let second):
            switch (first.compacted(), second.compacted()) {
            case (let first?, let second?):
                return .split(direction: direction, first: first, second: second)
            case (let remaining?, nil), (nil, let remaining?):
                return remaining
            case (nil, nil):
                return nil
            }
        }
    }

    func removingTab(_ sessionId: String) -> TerminalLayoutNode? {
        var next = self
        if let pane = paneContaining(sessionId) {
            next = next.updatingPane(pane.id) { _ = $0.removeTab(sessionId) }
        }
        return next.compacted()
    }

    func pruning(validSessionIds: Set<String>) -> TerminalLayoutNode? {
        switch self {
        case .pane(var group):
            return group.keepValidTabs(validSessionIds) ? nil : .pane(group)
        case .split(let direction, let first, let second):
            switch (
                first.pruning(validSessionIds: validSessionIds),
                second.pruning(validSessionIds: validSessionIds)
            ) {
            case (let first?, let second?):
                return .split(direction: direction, first: first, second: second)
            case (let remaining?, nil), (nil, let remaining?):
                return remaining
            case (nil, nil):
                return nil
            }
        }
    }
}

struct WorkspaceTerminalLayout: Codable, Equatable {
    var root: TerminalLayoutNode?
    var focusedPaneId: String?

    init(root: TerminalLayoutNode? = nil, focusedPaneId: String? = nil) {
        self.root = root
        self.focusedPaneId = focusedPaneId ?? root?.panes.first?.id
    }

    var focusedPane: PaneTabGroup? {
        guard let focusedPaneId else { return root?.panes.first }
        return root?.pane(withId: focusedPaneId) ?? root?.panes.first
    }

    var focusedSessionId: String? {
        focusedPane?.selectedSessionId
    }

    // 把会话并入布局:已在某窗格则选中该标签,否则加进焦点窗格(无树则新建窗格)
    mutating func adopt(_ sessionId: String) {
        if let pane = root?.paneContaining(sessionId) {
            root = root?.updatingPane(pane.id) { $0.selectedSessionId = sessionId }
            focusedPaneId = pane.id
            return
        }
        if let pane = focusedPane {
            root = root?.updatingPane(pane.id) { $0.appendTab(sessionId) }
            focusedPaneId = pane.id
        } else {
            let pane = PaneTabGroup(sessionIds: [sessionId])
            root = .pane(pane)
            focusedPaneId = pane.id
        }
    }

    mutating func selectTab(_ sessionId: String, inPane paneId: String) {
        root = root?.updatingPane(paneId) { pane in
            if pane.sessionIds.contains(sessionId) { pane.selectedSessionId = sessionId }
        }
        focusedPaneId = paneId
    }

    mutating func split(
        fromPane paneId: String,
        direction: TerminalSplitDirection,
        newSessionId: String
    ) {
        let newPane = PaneTabGroup(sessionIds: [newSessionId])
        root = root?.splitting(paneId: paneId, direction: direction, newPane: newPane)
        focusedPaneId = newPane.id
    }

    mutating func removeTab(_ sessionId: String) {
        root = root?.removingTab(sessionId)
        reconcileFocus()
    }

    // 拖拽:把标签移入目标窗格 index 处(负数表示末尾)
    mutating func moveTab(_ sessionId: String, toPane paneId: String, at index: Int?) {
        guard root?.pane(withId: paneId) != nil else { return }
        if let source = root?.paneContaining(sessionId), source.id != paneId {
            root = root?.updatingPane(source.id) { _ = $0.removeTab(sessionId) }
        }
        root = root?.updatingPane(paneId) { pane in
            if let index {
                pane.insertTab(sessionId, at: index)
            } else {
                pane.sessionIds.removeAll { $0 == sessionId }
                pane.appendTab(sessionId)
            }
        }
        root = root?.compacted()
        focusedPaneId = paneId
        reconcileFocus()
    }

    // 拖拽分屏:把标签从原窗格摘出,在目标窗格边缘生成新窗格
    mutating func moveTabToSplit(
        _ sessionId: String,
        ofPane paneId: String,
        direction: TerminalSplitDirection,
        newPaneFirst: Bool = false
    ) {
        guard let target = root?.pane(withId: paneId) else { return }
        // 单标签窗格拖到自己边缘没有意义
        if target.sessionIds == [sessionId] { return }
        if let source = root?.paneContaining(sessionId) {
            root = root?.updatingPane(source.id) { _ = $0.removeTab(sessionId) }
        }
        let newPane = PaneTabGroup(sessionIds: [sessionId])
        root = root?.splitting(
            paneId: paneId, direction: direction, newPane: newPane, newPaneFirst: newPaneFirst
        )
        root = root?.compacted()
        focusedPaneId = newPane.id
        reconcileFocus()
    }

    mutating func prune(validSessionIds: Set<String>) {
        root = root?.pruning(validSessionIds: validSessionIds)
        reconcileFocus()
    }

    private mutating func reconcileFocus() {
        guard let root else {
            focusedPaneId = nil
            return
        }
        if let focusedPaneId, root.pane(withId: focusedPaneId) != nil { return }
        focusedPaneId = root.panes.first?.id
    }
}

struct WorkbenchLayoutSnapshot: Codable, Equatable {
    var selectedWorkspaceId: String?
    var workspaceLayouts: [String: WorkspaceTerminalLayout]
    var leftSidebarVisible: Bool
    var inspectorVisible: Bool
}
