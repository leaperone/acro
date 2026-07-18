// Bonsplit 快照类型的 acro 最小重建。
// 上游 Bonsplit(manaflow-ai 私有 vendored 库)未随 cmux 发布;本文件按
// CmuxPanes(GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.)
// 的使用面重建等价接口,仅覆盖 CmuxPanes 需要的快照与控制器 seam。

import Foundation

public struct TabID: Hashable, Sendable, Codable {
    public let uuid: UUID

    public init() {
        uuid = UUID()
    }

    public init(uuid: UUID) {
        self.uuid = uuid
    }
}

public struct PixelRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ExternalTabNode: Hashable, Sendable {
    public let id: TabID

    public init(id: TabID) {
        self.id = id
    }
}

public indirect enum ExternalTreeNode: Sendable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)
}

public struct ExternalPaneNode: Sendable {
    public let id: String
    public let frame: PixelRect
    public let tabs: [ExternalTabNode]
    public let selectedTabId: TabID?

    public init(id: String, frame: PixelRect, tabs: [ExternalTabNode], selectedTabId: TabID?) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.selectedTabId = selectedTabId
    }
}

public struct ExternalSplitNode: Sendable {
    public let id: String
    public let orientation: String
    public let dividerPosition: Double
    public let first: ExternalTreeNode
    public let second: ExternalTreeNode

    public init(
        id: String,
        orientation: String,
        dividerPosition: Double,
        first: ExternalTreeNode,
        second: ExternalTreeNode
    ) {
        self.id = id
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}

// 布局计划的应用 seam;acro 侧由 WorkbenchModel 实现
@MainActor
public protocol BonsplitController: AnyObject {
    @discardableResult
    func setDividerPosition(_ position: Double, forSplit splitId: UUID, fromExternal: Bool) -> Bool
}

public enum SplitOrientation: String, Sendable, Codable {
    case horizontal
    case vertical
}
