import XCTest
@testable import AcroDesktop

final class RuntimeConnectionTests: XCTestCase {
    @MainActor
    func testSuccessfulSnapshotCompletesInitialConnection() {
        let connection = RuntimeConnection()
        let server = ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(),
            endpoints: ["127.0.0.1:1"]
        )
        connection.connect(server: server)
        defer { connection.disconnect() }
        XCTAssertEqual(connection.state, .connecting)

        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: []
        )

        XCTAssertEqual(connection.state, .connected)
        XCTAssertTrue(connection.snapshotLoaded)
        XCTAssertEqual(connection.snapshotRevision, 1)
        XCTAssertEqual(connection.reconnectAttempt, 0)
    }
}
