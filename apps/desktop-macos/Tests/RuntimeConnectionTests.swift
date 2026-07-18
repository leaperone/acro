import XCTest
@testable import AcroDesktop

final class RuntimeConnectionTests: XCTestCase {
    @MainActor
    func testConcurrentRefreshesCoalesceWithOneTrailingRefresh() async {
        var loadCount = 0
        var activeLoads = 0
        var maxActiveLoads = 0
        var firstRelease: CheckedContinuation<Void, Never>?
        var secondRelease: CheckedContinuation<Void, Never>?
        let connection = RuntimeConnection {
            loadCount += 1
            activeLoads += 1
            defer { activeLoads -= 1 }
            maxActiveLoads = max(maxActiveLoads, activeLoads)
            if loadCount == 1 {
                await withCheckedContinuation { firstRelease = $0 }
            } else if loadCount == 2 {
                await withCheckedContinuation { secondRelease = $0 }
            }
            return RuntimeConnection.RefreshSnapshot(
                workspaceGroups: [], workspaces: [], sessions: [], focus: []
            )
        }

        let firstCall = Task { await connection.refresh() }
        for _ in 0..<1_000 where firstRelease == nil { await Task.yield() }
        guard let firstRelease else { return XCTFail("first refresh did not start") }

        var startedFollowers = 0
        var finishedFollowers = 0
        let followers = (0..<20).map { _ in
            Task {
                startedFollowers += 1
                let result = await connection.refresh()
                finishedFollowers += 1
                return result
            }
        }
        for _ in 0..<1_000 where startedFollowers < followers.count { await Task.yield() }
        XCTAssertEqual(startedFollowers, followers.count)

        firstRelease.resume()
        for _ in 0..<1_000 where secondRelease == nil { await Task.yield() }
        guard let secondRelease else { return XCTFail("trailing refresh did not start") }
        XCTAssertEqual(finishedFollowers, 0)

        secondRelease.resume()
        let firstResult = await firstCall.value
        XCTAssertTrue(firstResult)
        for call in followers {
            let result = await call.value
            XCTAssertTrue(result)
        }

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(maxActiveLoads, 1)
        XCTAssertEqual(connection.snapshotRevision, 2)
    }

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
