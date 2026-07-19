import XCTest
@testable import AcroDesktop

final class TerminalPanesInteractionTests: XCTestCase {
    func testPaneDropZonesMatchBonsplitGeometry() {
        let size = CGSize(width: 400, height: 320)

        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 99, y: 160), in: size), .left)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 301, y: 160), in: size), .right)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 200, y: 79), in: size), .top)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 200, y: 241), in: size), .bottom)
        XCTAssertEqual(PaneDropZone.zone(at: CGPoint(x: 200, y: 160), in: size), .center)
    }
}
