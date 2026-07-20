import AppKit
import SwiftUI
import XCTest
@testable import AcroDesktop

@MainActor
final class TabBarWindowDragAreaTests: XCTestCase {
    func testShowsWindowDragHandleInRemainingTabBarSpace() {
        let host = makeHost(tabCount: 2, width: 500)
        let frames = windowDragHandleFrames(in: host)

        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else {
            XCTFail("Expected the remaining tab-bar space to contain a window drag handle")
            return
        }
        XCTAssertGreaterThan(frame.width, 250)
        XCTAssertEqual(frame.height, 28, accuracy: 0.5)
    }

    func testFallsBackToScrollingWithoutCoveringOverflowingTabs() {
        let host = makeHost(tabCount: 8, width: 500)

        XCTAssertTrue(windowDragHandleFrames(in: host).isEmpty)
    }

    private func makeHost(tabCount: Int, width: CGFloat) -> NSHostingView<AnyView> {
        let root = AnyView(
            TabBarWindowDragArea {
                ForEach(0..<tabCount, id: \.self) { index in
                    Text("Tab \(index)")
                        .frame(width: 100, height: 28)
                }
            }
            .frame(width: width, height: 28)
        )

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func windowDragHandleFrames(in view: NSView) -> [NSRect] {
        let ownFrames = view is WindowDragNSView ? [view.convert(view.bounds, to: nil)] : []
        return ownFrames + view.subviews.flatMap(windowDragHandleFrames)
    }
}
