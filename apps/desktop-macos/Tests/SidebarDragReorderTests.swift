import XCTest
import UniformTypeIdentifiers
@testable import AcroDesktop

final class SidebarDragReorderTests: XCTestCase {
    func testDropEdgeUsesRowHalf() {
        XCTAssertEqual(SidebarWorkspaceDropEdge.resolve(locationY: 15, height: 40), .top)
        XCTAssertEqual(SidebarWorkspaceDropEdge.resolve(locationY: 20, height: 40), .bottom)
    }

    func testSidebarDragTypesArePrivateAndDistinct() {
        XCTAssertNotEqual(UTType.acroSidebarWorkspace, .text)
        XCTAssertNotEqual(UTType.acroSidebarServer, .text)
        XCTAssertNotEqual(UTType.acroSidebarWorkspace, .acroSidebarServer)
    }

    func testPlannerInsertsBeforeAndAfterTarget() {
        let ids = ["a", "b", "c"]

        XCTAssertNil(
            SidebarWorkspaceDropPlanner.insertionIndex(
                draggedWorkspaceId: "a",
                targetWorkspaceId: "b",
                orderedWorkspaceIds: ids,
                edge: .top
            )
        )
        XCTAssertEqual(
            SidebarWorkspaceDropPlanner.insertionIndex(
                draggedWorkspaceId: "a",
                targetWorkspaceId: "b",
                orderedWorkspaceIds: ids,
                edge: .bottom
            ),
            1
        )
        XCTAssertEqual(
            SidebarWorkspaceDropPlanner.insertionIndex(
                draggedWorkspaceId: "c",
                targetWorkspaceId: "a",
                orderedWorkspaceIds: ids,
                edge: .top
            ),
            0
        )
    }

    func testPlannerSuppressesNoOpAndSupportsCrossGroupMove() {
        let ids = ["a", "b", "c"]

        XCTAssertNil(
            SidebarWorkspaceDropPlanner.insertionIndex(
                draggedWorkspaceId: "b",
                targetWorkspaceId: "a",
                orderedWorkspaceIds: ids,
                edge: .bottom
            )
        )
        XCTAssertEqual(
            SidebarWorkspaceDropPlanner.insertionIndex(
                draggedWorkspaceId: "outside",
                targetWorkspaceId: "b",
                orderedWorkspaceIds: ids,
                edge: .bottom
            ),
            2
        )
    }

    func testServerPlannerUsesTheSameRemoteOrderInBothSidebarViews() {
        let ids = ["a", "b", "c"]

        XCTAssertEqual(
            SidebarServerDropPlanner.insertionIndex(
                draggedServerId: "c",
                targetServerId: "a",
                targetIsLocal: false,
                orderedRemoteServerIds: ids,
                edge: .top
            ),
            0
        )
        XCTAssertEqual(
            SidebarServerDropPlanner.insertionIndex(
                draggedServerId: "b",
                targetServerId: "local",
                targetIsLocal: true,
                orderedRemoteServerIds: ids,
                edge: .bottom
            ),
            0
        )
        XCTAssertNil(
            SidebarServerDropPlanner.insertionIndex(
                draggedServerId: "a",
                targetServerId: "local",
                targetIsLocal: true,
                orderedRemoteServerIds: ids,
                edge: .bottom
            )
        )
    }
}
