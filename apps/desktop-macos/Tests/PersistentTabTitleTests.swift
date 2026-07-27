import Foundation
import Testing
@testable import AcroDesktop

@Suite
struct PersistentTabTitleTests {
    @Test
    func layoutRoundTripPreservesCustomTitles() throws {
        let data = Data(#"{"root":null,"focusedPaneId":null,"customTitlesBySessionId":{"session":"Build"}}"#.utf8)
        let layout = try JSONDecoder().decode(WorkspaceTerminalLayout.self, from: data)
        let encoded = try JSONEncoder().encode(layout)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(
            object["customTitlesBySessionId"] as? [String: String]
                == ["session": "Build"]
        )
    }
}
