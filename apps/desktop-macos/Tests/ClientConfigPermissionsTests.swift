import Darwin
import Foundation
import XCTest

@testable import AcroDesktop

final class ClientConfigPermissionsTests: XCTestCase {
    func testSaveRepairsDirectoryAndFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-client-config-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("config")
        let file = directory.appendingPathComponent("client.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(
            atPath: file.path, contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644])
        setenv("ACRO_CLIENT_CONFIG", file.path, 1)
        defer {
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        ClientConfig(v: 2, servers: [], active: nil).save()

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber)
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(directoryMode.intValue, 0o700)
        XCTAssertEqual(fileMode.intValue, 0o600)
    }
}
