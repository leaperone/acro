// 工作区布局树:分屏节点的叶子是"标签组窗格"(cmux/Bonsplit 模型——
// 每个窗格自带一组标签,split 与 tab 同树)。纯值类型,不依赖 UI。
// 分屏几何(均分/比例)由 Vendor/CmuxPanes 计算,经 externalTree 桥接。

import Bonsplit
import CmuxPanes
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

// 分屏节点:id 供几何计划寻址,ratio 是第一子的空间占比
struct SplitNode: Equatable {
    let id: String
    var direction: TerminalSplitDirection
    var ratio: Double
    var first: TerminalLayoutNode
    var second: TerminalLayoutNode

    init(
        id: String = UUID().uuidString,
        direction: TerminalSplitDirection,
        ratio: Double = 0.5,
        first: TerminalLayoutNode,
        second: TerminalLayoutNode
    ) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

extension SplitNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(TerminalSplitDirection.self, forKey: .direction)
        first = try container.decode(TerminalLayoutNode.self, forKey: .first)
        second = try container.decode(TerminalLayoutNode.self, forKey: .second)
        // 旧版持久化没有 id/ratio:补默认值
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        ratio = try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
    }
}

indirect enum TerminalLayoutNode: Equatable {
    case pane(PaneTabGroup)
    case split(SplitNode)

    var panes: [PaneTabGroup] {
        switch self {
        case .pane(let group):
            [group]
        case .split(let node):
            node.first.panes + node.second.panes
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
        case .split(var node):
            node.first = node.first.updatingPane(paneId, transform: transform)
            node.second = node.second.updatingPane(paneId, transform: transform)
            return .split(node)
        }
    }

    func updatingSplit(_ splitId: UUID, transform: (inout SplitNode) -> Void) -> TerminalLayoutNode {
        switch self {
        case .pane:
            return self
        case .split(var node):
            node.first = node.first.updatingSplit(splitId, transform: transform)
            node.second = node.second.updatingSplit(splitId, transform: transform)
            if UUID(uuidString: node.id) == splitId {
                transform(&node)
            }
            return .split(node)
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
                ? .split(SplitNode(direction: direction, first: .pane(newPane), second: self))
                : .split(SplitNode(direction: direction, first: self, second: .pane(newPane)))
        case .split(var node):
            node.first = node.first.splitting(
                paneId: paneId, direction: direction, newPane: newPane, newPaneFirst: newPaneFirst
            )
            node.second = node.second.splitting(
                paneId: paneId, direction: direction, newPane: newPane, newPaneFirst: newPaneFirst
            )
            return .split(node)
        }
    }

    // 摘掉空窗格;整棵树空则返回 nil
    func compacted() -> TerminalLayoutNode? {
        switch self {
        case .pane(let group):
            return group.sessionIds.isEmpty ? nil : self
        case .split(var node):
            switch (node.first.compacted(), node.second.compacted()) {
            case (let first?, let second?):
                node.first = first
                node.second = second
                return .split(node)
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
        case .split(var node):
            switch (
                node.first.pruning(validSessionIds: validSessionIds),
                node.second.pruning(validSessionIds: validSessionIds)
            ) {
            case (let first?, let second?):
                node.first = first
                node.second = second
                return .split(node)
            case (let remaining?, nil), (nil, let remaining?):
                return remaining
            case (nil, nil):
                return nil
            }
        }
    }

    // 桥接 CmuxPanes 几何:Bonsplit 快照树(frame 仅均分不需要,置零)
    var externalTree: ExternalTreeNode {
        switch self {
        case .pane(let group):
            .pane(ExternalPaneNode(
                id: group.id,
                frame: PixelRect(x: 0, y: 0, width: 0, height: 0),
                tabs: [],
                selectedTabId: nil
            ))
        case .split(let node):
            .split(ExternalSplitNode(
                id: node.id,
                orientation: node.direction == .horizontal ? "horizontal" : "vertical",
                dividerPosition: node.ratio,
                first: node.first.externalTree,
                second: node.second.externalTree
            ))
        }
    }
}

extension TerminalLayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case pane, split
    }

    // 合成编码把关联值包在 "_0" 里,旧数据是这个形状
    private enum WrappedKeys: String, CodingKey {
        case wrapped = "_0"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pane) {
            if let nested = try? container.nestedContainer(keyedBy: WrappedKeys.self, forKey: .pane),
               let group = try? nested.decode(PaneTabGroup.self, forKey: .wrapped) {
                self = .pane(group)
            } else {
                self = .pane(try container.decode(PaneTabGroup.self, forKey: .pane))
            }
            return
        }
        self = .split(try container.decode(SplitNode.self, forKey: .split))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let group):
            try container.encode(group, forKey: .pane)
        case .split(let node):
            try container.encode(node, forKey: .split)
        }
    }
}

// vim 式方向导航(⌘⇧HJKL):h 左 j 下 k 上 l 右
enum PaneDirection {
    case left, right, up, down
}

extension TerminalLayoutNode {
    // 按 ratio 递归切分单位矩形,得到每个窗格的几何位置
    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(pane: PaneTabGroup, frame: CGRect)] {
        switch self {
        case .pane(let group):
            return [(group, rect)]
        case .split(let node):
            let ratio = CGFloat(node.ratio)
            let firstRect: CGRect
            let secondRect: CGRect
            if node.direction == .horizontal {
                firstRect = CGRect(
                    x: rect.minX, y: rect.minY,
                    width: rect.width * ratio, height: rect.height
                )
                secondRect = CGRect(
                    x: rect.minX + rect.width * ratio, y: rect.minY,
                    width: rect.width * (1 - ratio), height: rect.height
                )
            } else {
                firstRect = CGRect(
                    x: rect.minX, y: rect.minY,
                    width: rect.width, height: rect.height * ratio
                )
                secondRect = CGRect(
                    x: rect.minX, y: rect.minY + rect.height * ratio,
                    width: rect.width, height: rect.height * (1 - ratio)
                )
            }
            return node.first.paneFrames(in: firstRect) + node.second.paneFrames(in: secondRect)
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

    // Ctrl+Tab 按布局树顺序跨全部分屏与标签循环。
    func adjacentTab(offset: Int) -> (sessionId: String, paneId: String)? {
        guard let root, let focusedSessionId else { return nil }
        let sessionIds = root.sessionIds
        guard sessionIds.count > 1,
              let index = sessionIds.firstIndex(of: focusedSessionId)
        else { return nil }
        let sessionId = sessionIds[(index + offset + sessionIds.count) % sessionIds.count]
        guard let paneId = root.paneContaining(sessionId)?.id else { return nil }
        return (sessionId, paneId)
    }

    func tab(number: Int) -> (sessionId: String, paneId: String)? {
        guard let pane = focusedPane,
              let index = NumberedShortcutMapper.index(
                  forDigit: number, count: pane.sessionIds.count
              )
        else { return nil }
        return (pane.sessionIds[index], pane.id)
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
        // 会话可能已被 reconcile 并入某窗格(session.create 后 refresh 先到):先摘除,避免双占位
        if let source = root?.paneContaining(newSessionId) {
            root = root?.updatingPane(source.id) { _ = $0.removeTab(newSessionId) }
        }
        let newPane = PaneTabGroup(sessionIds: [newSessionId])
        root = root?.splitting(paneId: paneId, direction: direction, newPane: newPane)
        focusedPaneId = newPane.id
        reconcileFocus()
    }

    mutating func removeTab(_ sessionId: String) {
        root = root?.removingTab(sessionId)
        reconcileFocus()
    }

    // 拖拽:把标签移入目标窗格 index 处(nil 表示末尾)
    mutating func moveTab(_ sessionId: String, toPane paneId: String, at index: Int?) {
        guard root?.pane(withId: paneId) != nil else { return }
        let source = root?.paneContaining(sessionId)
        // 拖起又落回本窗格空白处(反悔动作):只选中,不改变标签顺序
        if source?.id == paneId, index == nil {
            selectTab(sessionId, inPane: paneId)
            return
        }
        // 同窗格向后拖:先摘除自身会让目标位左移一格;不修正会落到插入指示器的右边
        var targetIndex = index
        if let source, source.id == paneId, let index,
           let sourceIndex = source.sessionIds.firstIndex(of: sessionId), sourceIndex < index {
            targetIndex = index - 1
        }
        if let source, source.id != paneId {
            root = root?.updatingPane(source.id) { _ = $0.removeTab(sessionId) }
        }
        root = root?.updatingPane(paneId) { pane in
            if let targetIndex {
                pane.insertTab(sessionId, at: targetIndex)
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

    // 拖动分隔线;clamp 与 cmux resize 计划一致(0.1-0.9)
    mutating func setSplitRatio(_ splitId: UUID, ratio: Double) {
        root = root?.updatingSplit(splitId) { node in
            node.ratio = min(max(ratio, 0.1), 0.9)
        }
    }

    // 均分所有窗格:CmuxPanes 的 equalizeDividerPlan(cmux 均分算法原样)
    mutating func equalizeSplits() {
        guard let root else { return }
        let plan = root.externalTree.equalizeDividerPlan()
        guard plan.foundSplit else { return }
        var next = root
        for adjustment in plan.adjustments {
            next = next.updatingSplit(adjustment.splitId) { node in
                node.ratio = min(max(Double(adjustment.position), 0.1), 0.9)
            }
        }
        self.root = next
    }

    // 方向邻居:候选须整体越过焦点窗格对应边缘;
    // 垂直/水平投影重叠大的优先,重叠相同再比边缘距离
    func paneId(toward direction: PaneDirection) -> String? {
        guard let root, let focusedPane else { return nil }
        let frames = root.paneFrames()
        guard let focus = frames.first(where: { $0.pane.id == focusedPane.id })?.frame else {
            return nil
        }
        let eps: CGFloat = 0.0001
        var best: (id: String, overlap: CGFloat, distance: CGFloat)?
        for (pane, frame) in frames where pane.id != focusedPane.id {
            let beyond: Bool
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                beyond = frame.maxX <= focus.minX + eps
                distance = focus.minX - frame.maxX
                overlap = min(frame.maxY, focus.maxY) - max(frame.minY, focus.minY)
            case .right:
                beyond = frame.minX >= focus.maxX - eps
                distance = frame.minX - focus.maxX
                overlap = min(frame.maxY, focus.maxY) - max(frame.minY, focus.minY)
            case .up:
                beyond = frame.maxY <= focus.minY + eps
                distance = focus.minY - frame.maxY
                overlap = min(frame.maxX, focus.maxX) - max(frame.minX, focus.minX)
            case .down:
                beyond = frame.minY >= focus.maxY - eps
                distance = frame.minY - focus.maxY
                overlap = min(frame.maxX, focus.maxX) - max(frame.minX, focus.minX)
            }
            guard beyond else { continue }
            if let current = best {
                if overlap > current.overlap + eps
                    || (abs(overlap - current.overlap) <= eps && distance < current.distance - eps) {
                    best = (pane.id, overlap, distance)
                }
            } else {
                best = (pane.id, overlap, distance)
            }
        }
        return best?.id
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

struct ScopedResourceID: Hashable {
    let serverId: String
    let resourceId: String
}

struct WorkbenchLayoutSnapshot: Codable, Equatable {
    // 多主机:记住上次查看的服务器(旧快照无此字段,解码为 nil)
    var selectedServerId: String?
    var selectedWorkspaceId: String?
    var workspaceLayouts: [ScopedResourceID: WorkspaceTerminalLayout]
    var leftSidebarVisible: Bool
    var inspectorVisible: Bool

    private enum CodingKeys: String, CodingKey {
        case selectedServerId, selectedWorkspaceId, workspaceLayouts
        case leftSidebarVisible, inspectorVisible
    }

    init(
        selectedServerId: String?,
        selectedWorkspaceId: String?,
        workspaceLayouts: [ScopedResourceID: WorkspaceTerminalLayout],
        leftSidebarVisible: Bool,
        inspectorVisible: Bool
    ) {
        self.selectedServerId = selectedServerId
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaceLayouts = workspaceLayouts
        self.leftSidebarVisible = leftSidebarVisible
        self.inspectorVisible = inspectorVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedServerId = try container.decodeIfPresent(String.self, forKey: .selectedServerId)
        selectedWorkspaceId = try container.decodeIfPresent(String.self, forKey: .selectedWorkspaceId)
        leftSidebarVisible = try container.decode(Bool.self, forKey: .leftSidebarVisible)
        inspectorVisible = try container.decode(Bool.self, forKey: .inspectorVisible)

        if let layoutsByServer = try? container.decode(
            [String: [String: WorkspaceTerminalLayout]].self,
            forKey: .workspaceLayouts
        ) {
            workspaceLayouts = layoutsByServer.reduce(into: [:]) { result, server in
                for (workspaceId, layout) in server.value {
                    result[ScopedResourceID(serverId: server.key, resourceId: workspaceId)] = layout
                }
            }
        } else {
            // v2 旧快照只有裸 workspaceId。先挂到快照记录的服务器；
            // 更老的快照没有 selectedServerId，restore 时再归到当前服务器。
            let legacy = try container.decode(
                [String: WorkspaceTerminalLayout].self,
                forKey: .workspaceLayouts
            )
            let legacyServerId = selectedServerId ?? ""
            workspaceLayouts = legacy.reduce(into: [:]) { result, item in
                result[ScopedResourceID(
                    serverId: legacyServerId,
                    resourceId: item.key
                )] = item.value
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedServerId, forKey: .selectedServerId)
        try container.encodeIfPresent(selectedWorkspaceId, forKey: .selectedWorkspaceId)
        try container.encode(leftSidebarVisible, forKey: .leftSidebarVisible)
        try container.encode(inspectorVisible, forKey: .inspectorVisible)
        let layoutsByServer = workspaceLayouts.reduce(
            into: [String: [String: WorkspaceTerminalLayout]]()
        ) { result, item in
            result[item.key.serverId, default: [:]][item.key.resourceId] = item.value
        }
        try container.encode(layoutsByServer, forKey: .workspaceLayouts)
    }

    func workspaceLayouts(scopedTo fallbackServerId: String?) -> [
        ScopedResourceID: WorkspaceTerminalLayout
    ] {
        guard let fallbackServerId, !fallbackServerId.isEmpty else { return workspaceLayouts }
        return workspaceLayouts.reduce(into: [:]) { result, item in
            let key = item.key.serverId.isEmpty
                ? ScopedResourceID(serverId: fallbackServerId, resourceId: item.key.resourceId)
                : item.key
            result[key] = item.value
        }
    }
}
