import Foundation

enum TerminalSplitDirection: String, Codable, Equatable {
    case horizontal
    case vertical
}

indirect enum TerminalLayoutNode: Codable, Equatable {
    case leaf(String)
    case split(
        direction: TerminalSplitDirection,
        first: TerminalLayoutNode,
        second: TerminalLayoutNode
    )

    var sessionIds: [String] {
        switch self {
        case .leaf(let sessionId):
            [sessionId]
        case .split(_, let first, let second):
            first.sessionIds + second.sessionIds
        }
    }

    var firstSessionId: String? {
        sessionIds.first
    }

    func contains(_ sessionId: String) -> Bool {
        switch self {
        case .leaf(let current):
            current == sessionId
        case .split(_, let first, let second):
            first.contains(sessionId) || second.contains(sessionId)
        }
    }

    func replacing(_ sessionId: String, with replacement: String) -> TerminalLayoutNode {
        switch self {
        case .leaf(let current):
            current == sessionId ? .leaf(replacement) : self
        case .split(let direction, let first, let second):
            .split(
                direction: direction,
                first: first.replacing(sessionId, with: replacement),
                second: second.replacing(sessionId, with: replacement)
            )
        }
    }

    func splitting(
        _ sessionId: String,
        direction: TerminalSplitDirection,
        newSessionId: String
    ) -> TerminalLayoutNode {
        switch self {
        case .leaf(let current):
            guard current == sessionId else { return self }
            return .split(
                direction: direction,
                first: self,
                second: .leaf(newSessionId)
            )
        case .split(let currentDirection, let first, let second):
            return .split(
                direction: currentDirection,
                first: first.splitting(sessionId, direction: direction, newSessionId: newSessionId),
                second: second.splitting(sessionId, direction: direction, newSessionId: newSessionId)
            )
        }
    }

    func removing(_ sessionId: String) -> TerminalLayoutNode? {
        switch self {
        case .leaf(let current):
            current == sessionId ? nil : self
        case .split(let direction, let first, let second):
            switch (first.removing(sessionId), second.removing(sessionId)) {
            case (let first?, let second?):
                .split(direction: direction, first: first, second: second)
            case (let remaining?, nil), (nil, let remaining?):
                remaining
            case (nil, nil):
                nil
            }
        }
    }

    func pruning(validSessionIds: Set<String>) -> TerminalLayoutNode? {
        switch self {
        case .leaf(let sessionId):
            validSessionIds.contains(sessionId) ? self : nil
        case .split(let direction, let first, let second):
            switch (
                first.pruning(validSessionIds: validSessionIds),
                second.pruning(validSessionIds: validSessionIds)
            ) {
            case (let first?, let second?):
                .split(direction: direction, first: first, second: second)
            case (let remaining?, nil), (nil, let remaining?):
                remaining
            case (nil, nil):
                nil
            }
        }
    }
}

struct WorkspaceTerminalLayout: Codable, Equatable {
    var root: TerminalLayoutNode?
    var focusedSessionId: String?

    init(root: TerminalLayoutNode? = nil, focusedSessionId: String? = nil) {
        self.root = root
        self.focusedSessionId = focusedSessionId
    }

    mutating func prune(validSessionIds: Set<String>) {
        root = root?.pruning(validSessionIds: validSessionIds)
        if let focusedSessionId, !validSessionIds.contains(focusedSessionId) {
            self.focusedSessionId = root?.firstSessionId
        }
        if focusedSessionId == nil {
            focusedSessionId = root?.firstSessionId
        }
    }
}

struct WorkbenchLayoutSnapshot: Codable, Equatable {
    var selectedWorkspaceId: String?
    var workspaceLayouts: [String: WorkspaceTerminalLayout]
    var leftSidebarVisible: Bool
    var inspectorVisible: Bool
}
