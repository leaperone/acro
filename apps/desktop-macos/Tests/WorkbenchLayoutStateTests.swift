import XCTest
@testable import AcroDesktop

final class WorkbenchLayoutStateTests: XCTestCase {
    func testSplitRemovePruneAndRoundTrip() throws {
        let root = TerminalLayoutNode.leaf("one")
            .splitting("one", direction: .horizontal, newSessionId: "two")
            .splitting("two", direction: .vertical, newSessionId: "three")

        XCTAssertEqual(root.sessionIds, ["one", "two", "three"])
        XCTAssertEqual(root.removing("two")?.sessionIds, ["one", "three"])
        XCTAssertEqual(root.pruning(validSessionIds: ["three"])?.sessionIds, ["three"])

        var layout = WorkspaceTerminalLayout(root: root, focusedSessionId: "hidden")
        layout.prune(validSessionIds: ["one", "two", "three", "hidden"])
        XCTAssertEqual(layout.focusedSessionId, "one")

        layout = WorkspaceTerminalLayout(root: root, focusedSessionId: "three")
        layout.remove("one")
        XCTAssertEqual(layout.root?.sessionIds, ["two", "three"])
        XCTAssertEqual(layout.focusedSessionId, "three")
        layout.remove("three")
        XCTAssertEqual(layout.focusedSessionId, "two")

        layout = WorkspaceTerminalLayout(root: root)
        layout.remove("one")
        XCTAssertEqual(layout.focusedSessionId, "two")

        let snapshot = WorkbenchLayoutSnapshot(
            selectedWorkspaceId: "workspace",
            workspaceLayouts: [
                "workspace": WorkspaceTerminalLayout(root: root, focusedSessionId: "three"),
            ],
            leftSidebarVisible: true,
            inspectorVisible: true
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data), snapshot)
    }
}
