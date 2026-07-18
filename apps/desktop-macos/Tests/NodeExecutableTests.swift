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
