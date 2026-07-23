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
        XCTAssertEqual(connection.snapshotRevision, 1)
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
        XCTAssertTrue(connection.readinessTimeoutPending)

        connection.handleAuthenticated(["deviceId": "device"])
        XCTAssertTrue(connection.readinessTimeoutPending)

        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: []
        )

        XCTAssertEqual(connection.state, .connected)
        XCTAssertTrue(connection.snapshotLoaded)
        XCTAssertEqual(connection.snapshotRevision, 1)
        XCTAssertEqual(connection.reconnectAttempt, 0)
        XCTAssertFalse(connection.readinessTimeoutPending)
        XCTAssertEqual(connection.recoveryState, .idle)
    }

    @MainActor
    func testInvalidLegacyServerConfigExposesARecoverableError() {
        let connection = RuntimeConnection()
        connection.connect(server: ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: "invalid", endpoints: ["127.0.0.1:8790"]
        ))
        defer { connection.disconnect() }

        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(connection.lastConnectionError, "服务器公钥无效,请重新配对")
        XCTAssertEqual(connection.reconnectAttempt, 0)
        XCTAssertEqual(connection.recoveryState, .configurationError)
    }

    @MainActor
    func testAllInvalidEndpointsBlockWithoutRetrying() {
        let connection = RuntimeConnection()
        connection.connect(server: ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(), endpoints: ["not an endpoint"]
        ))
        defer { connection.disconnect() }

        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(connection.recoveryState, .configurationError)
        XCTAssertEqual(connection.reconnectAttempt, 0)
        XCTAssertFalse(connection.readinessTimeoutPending)
    }

    @MainActor
    func testReadinessExpiryDisconnectsAndSchedulesOneRetry() {
        let connection = RuntimeConnection()
        connection.connect(server: ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(), endpoints: ["127.0.0.1:1"]
        ))
        defer { connection.disconnect() }

        connection.expireReadiness()

        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(connection.recoveryState, .retrying)
        XCTAssertEqual(connection.reconnectAttempt, 1)
        XCTAssertFalse(connection.readinessTimeoutPending)
    }

    @MainActor
    func testInitialSnapshotRetriesAfterTransientFailure() async {
        var loadCount = 0
        let connection = RuntimeConnection(
            refreshSnapshotProvider: {
                loadCount += 1
                if loadCount == 1 { throw RpcError(message: "transient") }
                return RuntimeConnection.RefreshSnapshot(
                    workspaceGroups: [], workspaces: [], sessions: [], focus: []
                )
            },
            initialRefreshDelays: [0]
        )
        connection.connect(server: ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(), endpoints: []
        ))
        defer { connection.disconnect() }

        connection.startInitialRefresh()
        for _ in 0..<1_000 where !connection.snapshotLoaded { await Task.yield() }

        XCTAssertTrue(connection.snapshotLoaded)
        XCTAssertEqual(connection.snapshotRevision, 1)
        XCTAssertEqual(loadCount, 2)
    }

    @MainActor
    func testDisconnectRejectsAnInFlightInitialSnapshot() async {
        var loadCount = 0
        var releaseLoad: CheckedContinuation<Void, Never>?
        let connection = RuntimeConnection(
            refreshSnapshotProvider: {
                loadCount += 1
                await withCheckedContinuation { releaseLoad = $0 }
                return RuntimeConnection.RefreshSnapshot(
                    workspaceGroups: [], workspaces: [], sessions: [], focus: []
                )
            },
            initialRefreshDelays: [10]
        )
        connection.connect(server: ServerEntry(
            localId: "server", name: "Server", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(), endpoints: []
        ))
        connection.startInitialRefresh()
        for _ in 0..<1_000 where releaseLoad == nil { await Task.yield() }
        guard let releaseLoad else { return XCTFail("initial refresh did not start") }

        connection.disconnect()
        releaseLoad.resume()
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(connection.snapshotLoaded)
        XCTAssertEqual(connection.state, .disconnected)
    }

    @MainActor
    func testServerSwitchInvalidatesCurrentAndTrailingRefreshJobs() async {
        var loadCount = 0
        var releaseLoad: CheckedContinuation<Void, Never>?
        let connection = RuntimeConnection {
            loadCount += 1
            await withCheckedContinuation { releaseLoad = $0 }
            return RuntimeConnection.RefreshSnapshot(
                workspaceGroups: [], workspaces: [], sessions: [], focus: []
            )
        }
        let firstServer = ServerEntry(
            localId: "first", name: "First", deviceId: "first", token: "first",
            pub: Data(repeating: 1, count: 32).base64EncodedString(), endpoints: []
        )
        let secondServer = ServerEntry(
            localId: "second", name: "Second", deviceId: "second", token: "second",
            pub: Data(repeating: 2, count: 32).base64EncodedString(), endpoints: []
        )
        connection.connect(server: firstServer)
        let current = Task { await connection.refresh() }
        for _ in 0..<1_000 where releaseLoad == nil { await Task.yield() }
        guard let releaseLoad else { return XCTFail("current refresh did not start") }
        let trailing = Task { await connection.refresh() }
        await Task.yield()

        connection.connect(server: secondServer)
        releaseLoad.resume()

        let currentResult = await current.value
        let trailingResult = await trailing.value
        XCTAssertFalse(currentResult)
        XCTAssertFalse(trailingResult)
        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(connection.snapshotLoaded)
        connection.disconnect()
    }
}
