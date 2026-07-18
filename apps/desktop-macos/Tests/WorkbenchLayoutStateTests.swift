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

@MainActor
final class AcroShortcutTests: XCTestCase {
    func testCommandWClosesOnceAndConsumesRepeats() throws {
        let terminal = AcroTerminalNSView(command: "true")
        var closeCount = 0
        terminal.onClose = { closeCount += 1 }

        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        XCTAssertNil(AcroAppDelegate.handleKeyDown(press, firstResponder: terminal))
        XCTAssertEqual(closeCount, 1)

        let repeated = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: true,
            keyCode: 13
        ))
        XCTAssertNil(AcroAppDelegate.handleKeyDown(repeated, firstResponder: terminal))
        XCTAssertEqual(closeCount, 1)
    }
}
