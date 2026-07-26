import XCTest

@testable import AcroDesktop

final class GhosttyConfigTests: XCTestCase {
    func testUserConfigPathsStayInsideXDGConfigHome() {
        XCTAssertEqual(
            Ghostty.userGhosttyConfigPaths(
                environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
                homeDirectory: "/Users/test"
            ),
            ["/tmp/xdg/ghostty/config", "/tmp/xdg/ghostty/config.ghostty"]
        )
        XCTAssertEqual(
            Ghostty.userGhosttyConfigPaths(
                environment: ["XDG_CONFIG_HOME": "relative/path"],
                homeDirectory: "/Users/test"
            ),
            [
                "/Users/test/.config/ghostty/config",
                "/Users/test/.config/ghostty/config.ghostty",
            ]
        )
        XCTAssertEqual(
            Ghostty.userGhosttyConfigPaths(
                environment: ["XDG_CONFIG_HOME": ""],
                homeDirectory: "/Users/test"
            ),
            [
                "/Users/test/.config/ghostty/config",
                "/Users/test/.config/ghostty/config.ghostty",
            ]
        )
    }
}
