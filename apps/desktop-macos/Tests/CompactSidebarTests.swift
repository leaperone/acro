import XCTest
@testable import AcroDesktop

final class CompactSidebarTests: XCTestCase {
    func testLayoutUsesFixedWidthThatContainsTrafficLights() {
        XCTAssertEqual(CompactSidebarLayout.width, 64)
        XCTAssertGreaterThanOrEqual(CompactSidebarLayout.width, 62)
        XCTAssertEqual(CompactSidebarLayout.serverSectionWidth, 56)
        XCTAssertEqual(
            CompactSidebarLayout.width - CompactSidebarLayout.serverSectionWidth,
            8
        )
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

    func testIdentityUsesUpToTwoVisibleCharacters() {
        XCTAssertEqual(CompactSidebarIdentity.mark(for: "  acro"), "AC")
        XCTAssertEqual(CompactSidebarIdentity.mark(for: " 工作区"), "工作")
        XCTAssertEqual(CompactSidebarIdentity.mark(for: " \n "), "•")
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
        XCTAssertEqual(sections[0].groupId, "group-a")
        XCTAssertEqual(sections[0].name, "A")
        XCTAssertEqual(sections[0].workspaces.map(\.id), [second.id, first.id])
        XCTAssertNil(sections[1].name)
        XCTAssertNil(sections[1].groupId)
        XCTAssertEqual(sections[1].workspaces.map(\.id), [third.id])
    }

    func testWorkspaceMenuSnapshotTracksConnectionAvailability() {
        let base = SidebarWorkspaceMenuSnapshot(
            canMutate: false,
            canMoveUp: false,
            canMoveDown: true,
            isInGroup: false,
            moveTargets: []
        )
        let connected = SidebarWorkspaceMenuSnapshot(
            canMutate: true,
            canMoveUp: base.canMoveUp,
            canMoveDown: base.canMoveDown,
            isInGroup: base.isInGroup,
            moveTargets: base.moveTargets
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
