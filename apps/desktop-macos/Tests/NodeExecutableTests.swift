import Foundation
import XCTest

@testable import AcroDesktop

final class NodeExecutableTests: XCTestCase {
    func testExplicitOverridePrecedesBundledAndRuntimeNode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-node-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let explicit = try executable(at: root.appendingPathComponent("explicit"))
        _ = try executable(at: root.appendingPathComponent("node"))
        let runtime = try executable(at: root.appendingPathComponent("runtime"))

        XCTAssertEqual(
            NodeExecutable.resolve(
                runtimeNode: runtime,
                environment: ["ACRO_NODE": explicit],
                resourcePath: root.path
            ),
            explicit
        )
    }

    func testBundledNodePrecedesRuntimeAndSystemCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-node-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundled = try executable(at: root.appendingPathComponent("node"))
        let runtime = try executable(at: root.appendingPathComponent("runtime"))

        XCTAssertEqual(
            NodeExecutable.resolve(
                runtimeNode: runtime,
                environment: [:],
                resourcePath: root.path
            ),
            bundled
        )
    }

    private func executable(at url: URL) throws -> String {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url.path
    }
}

final class LocalRuntimeRecoveryPolicyTests: XCTestCase {
    @MainActor
    func testExitedOwnedProcessIsConsumedBeforeAnotherSpawnDecision() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        var slot: Process? = child

        XCTAssertTrue(LocalRuntimeManager.consumeExitedProcess(&slot))
        XCTAssertNil(slot)
        XCTAssertFalse(LocalRuntimeManager.consumeExitedProcess(&slot))
    }

    func testAvailabilityClassificationDistinguishesUnavailableAndUnresponsive() {
        XCTAssertEqual(
            LocalRuntimeAvailability.classify(statusCode: 200, error: nil),
            .healthy
        )
        XCTAssertEqual(
            LocalRuntimeAvailability.classify(
                statusCode: nil,
                error: NSError(
                    domain: NSURLErrorDomain,
                    code: URLError.Code.cannotConnectToHost.rawValue
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            LocalRuntimeAvailability.classify(statusCode: 503, error: nil),
            .unresponsive
        )
        XCTAssertEqual(
            LocalRuntimeAvailability.classify(
                statusCode: nil,
                error: NSError(
                    domain: NSURLErrorDomain,
                    code: URLError.Code.timedOut.rawValue
                )
            ),
            .unresponsive
        )
    }

    func testExternalUnhealthyPortDoesNotSpawnBundledRuntime() {
        var policy = LocalRuntimeRecoveryPolicy(unhealthyLimit: 2)

        XCTAssertEqual(
            policy.action(availability: .unresponsive, ownsRunningProcess: false),
            .wait
        )
        XCTAssertEqual(
            policy.action(availability: .unavailable, ownsRunningProcess: false),
            .spawnBundled
        )
    }

    func testOwnedUnhealthyProcessIsTerminatedOnceAndCanRecover() {
        let now = Date(timeIntervalSince1970: 1_000)
        var policy = LocalRuntimeRecoveryPolicy(unhealthyLimit: 2, retryDelays: [2])

        XCTAssertEqual(
            policy.action(availability: .unresponsive, ownsRunningProcess: true),
            .wait
        )
        XCTAssertEqual(
            policy.action(availability: .unresponsive, ownsRunningProcess: true),
            .terminateOwned
        )
        XCTAssertEqual(
            policy.action(availability: .unresponsive, ownsRunningProcess: true),
            .wait
        )

        policy.ownedProcessExited(at: now)
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(1)
            ),
            .wait
        )
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(2)
            ),
            .spawnBundled
        )
        policy.ownedProcessStarted()
        XCTAssertEqual(
            policy.action(availability: .healthy, ownsRunningProcess: true),
            .ensurePaired
        )
        XCTAssertEqual(policy.consecutiveOwnedFailures, 0)
        XCTAssertFalse(policy.terminationRequested)
    }

    func testRepeatedSpawnFailuresBackOffUntilRuntimeBecomesHealthy() {
        let now = Date(timeIntervalSince1970: 2_000)
        var policy = LocalRuntimeRecoveryPolicy(retryDelays: [2, 5])

        policy.spawnFailed(at: now)
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(1)
            ),
            .wait
        )
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(2)
            ),
            .spawnBundled
        )

        policy.spawnFailed(at: now.addingTimeInterval(2))
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(6)
            ),
            .wait
        )
        XCTAssertEqual(
            policy.action(
                availability: .unavailable,
                ownsRunningProcess: false,
                now: now.addingTimeInterval(7)
            ),
            .spawnBundled
        )

        XCTAssertEqual(
            policy.action(availability: .healthy, ownsRunningProcess: true),
            .ensurePaired
        )
        XCTAssertNil(policy.retryNotBefore)
    }

    func testBackoffResetsOnlyAfterStableHealth() {
        let now = Date(timeIntervalSince1970: 3_000)
        var policy = LocalRuntimeRecoveryPolicy(
            stableHealthyLimit: 2,
            retryDelays: [2, 5]
        )

        policy.spawnFailed(at: now)
        _ = policy.action(availability: .healthy, ownsRunningProcess: true)
        policy.ownedProcessExited(at: now)
        XCTAssertEqual(policy.retryNotBefore, now.addingTimeInterval(5))

        _ = policy.action(availability: .healthy, ownsRunningProcess: true)
        _ = policy.action(availability: .healthy, ownsRunningProcess: true)
        policy.ownedProcessExited(at: now)
        XCTAssertEqual(policy.retryNotBefore, now.addingTimeInterval(2))
    }
}
