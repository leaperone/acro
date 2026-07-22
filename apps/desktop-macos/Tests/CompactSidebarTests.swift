import XCTest
@testable import AcroDesktop

final class CompactSidebarTests: XCTestCase {
    func testLayoutUsesFixedWidthThatContainsTrafficLights() {
        XCTAssertEqual(CompactSidebarLayout.width, 64)
        XCTAssertGreaterThanOrEqual(CompactSidebarLayout.width, 62)
    }

    func testMinimumWindowHasRoomForEverySidebarPresentation() {
        let wideContent = WorkbenchLayoutMetrics.minimumWindowWidth
            - WorkbenchLayoutMetrics.defaultSidebarWidth
        let compactContent = WorkbenchLayoutMetrics.minimumWindowWidth
            - CompactSidebarLayout.width
        let hiddenContent = WorkbenchLayoutMetrics.minimumWindowWidth

        XCTAssertGreaterThanOrEqual(wideContent, WorkbenchLayoutMetrics.minimumTerminalWidth)
        XCTAssertLessThan(wideContent, WorkbenchLayoutMetrics.inspectorVisibilityWidth)
        XCTAssertGreaterThanOrEqual(compactContent, WorkbenchLayoutMetrics.minimumTerminalWidth)
        XCTAssertLessThan(compactContent, WorkbenchLayoutMetrics.inspectorVisibilityWidth)
        XCTAssertGreaterThanOrEqual(
            hiddenContent,
            WorkbenchLayoutMetrics.minimumTerminalWidth
                + WorkbenchLayoutMetrics.minimumInspectorWidth
        )
    }

    func testIdentityUsesFirstVisibleCharacter() {
        XCTAssertEqual(CompactSidebarIdentity.initial(for: "  acro"), "A")
        XCTAssertEqual(CompactSidebarIdentity.initial(for: " 工作区"), "工")
        XCTAssertEqual(CompactSidebarIdentity.initial(for: " \n "), "•")
    }

    func testIdentityColorIsStable() {
        XCTAssertEqual(CompactSidebarIdentity.colorIndex(for: "workspace-a"), 0)
        XCTAssertEqual(CompactSidebarIdentity.colorIndex(for: "workspace-b"), 1)
        XCTAssertEqual(CompactSidebarIdentity.colorIndex(for: "server-a"), 4)
        XCTAssertEqual(CompactSidebarIdentity.colorIndex(for: "server-a", paletteCount: 0), 0)
    }

    func testProjectionPreservesGroupOrderAndAppendsUngroupedWorkspaces() {
        let first = workspace(id: "first", name: "First")
        let second = workspace(id: "second", name: "Second")
        let third = workspace(id: "third", name: "Third")
        let groups = [
            WorkspaceGroup(
                id: "group-a",
                name: "A",
                workspaceIds: [second.id, first.id],
                createdAt: ""
            ),
            WorkspaceGroup(
                id: "empty",
                name: "Empty",
                workspaceIds: ["missing"],
                createdAt: ""
            ),
        ]

        let sections = CompactSidebarProjection.sections(
            groups: groups,
            workspaces: [first, second, third]
        )

        XCTAssertEqual(sections.map(\.id), ["group:group-a", "ungrouped"])
        XCTAssertEqual(sections[0].name, "A")
        XCTAssertEqual(sections[0].workspaces.map(\.id), [second.id, first.id])
        XCTAssertNil(sections[1].name)
        XCTAssertEqual(sections[1].workspaces.map(\.id), [third.id])
    }

    func testWorkspaceSnapshotTracksConnectionAvailability() {
        let base = CompactSidebarWorkspaceSnapshot(
            id: "workspace",
            name: "Workspace",
            initial: "W",
            serverName: "Server",
            groupName: nil,
            sessionCount: 1,
            isSelected: true,
            canCreateTerminal: false
        )
        let connected = CompactSidebarWorkspaceSnapshot(
            id: base.id,
            name: base.name,
            initial: base.initial,
            serverName: base.serverName,
            groupName: base.groupName,
            sessionCount: base.sessionCount,
            isSelected: base.isSelected,
            canCreateTerminal: true
        )

        XCTAssertNotEqual(base, connected)
    }

    private func workspace(id: String, name: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            sessionIds: [],
            createdAt: "",
            layout: nil,
            layoutRev: nil
        )
    }
}
