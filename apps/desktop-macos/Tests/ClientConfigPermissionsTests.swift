import Darwin
import Foundation
import XCTest

@testable import AcroDesktop

final class ClientConfigPermissionsTests: XCTestCase {
    func testMissingConfigStartsAsEmptyWithoutCreatingAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-client-config-\(UUID().uuidString)")
        let file = root.appendingPathComponent("client.json")
        setenv("ACRO_CLIENT_CONFIG", file.path, 1)
        defer {
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        let config = try ClientConfig.loadForWrite()
        XCTAssertTrue(config.servers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptConfigCannotBeTreatedAsEmptyForWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-client-config-\(UUID().uuidString)")
        let file = root.appendingPathComponent("client.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        setenv("ACRO_CLIENT_CONFIG", file.path, 1)
        defer {
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertNil(ClientConfig.load())
        XCTAssertThrowsError(try ClientConfig.loadForWrite())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

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

    @MainActor
    func testRemoteServerReorderPinsLocalFirstAndPreservesActiveServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-server-order-\(UUID().uuidString)")
        let file = root.appendingPathComponent("client.json")
        setenv("ACRO_CLIENT_CONFIG", file.path, 1)
        let pub = Data(repeating: 1, count: 32).base64EncodedString()
        let firstRemote = ServerEntry(
            localId: "remote-a", name: "A", deviceId: "device-a", token: "token-a",
            pub: pub, endpoints: ["198.51.100.1:1"]
        )
        let local = ServerEntry(
            localId: "local", name: "Local", deviceId: "device-local", token: "token-local",
            pub: pub, endpoints: ["127.0.0.1:1"]
        )
        let secondRemote = ServerEntry(
            localId: "remote-b", name: "B", deviceId: "device-b", token: "token-b",
            pub: pub, endpoints: ["198.51.100.2:1"]
        )
        ClientConfig(
            v: 2,
            servers: [firstRemote, local, secondRemote],
            active: secondRemote.id
        ).save()
        let hub = RuntimeHub()
        hub.reload()
        defer {
            ClientConfig(v: 2, servers: [], active: nil).save()
            hub.reload()
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            SidebarServerProjection.entries(hub.entries).map(\.id),
            [local.id, firstRemote.id, secondRemote.id]
        )

        try ServerDirectory.reorderRemote(secondRemote.id, to: 0, hub: hub)

        let saved = try XCTUnwrap(ClientConfig.load())
        XCTAssertEqual(saved.servers.map(\.id), [local.id, secondRemote.id, firstRemote.id])
        XCTAssertEqual(saved.active, secondRemote.id)
        XCTAssertEqual(hub.entries.map(\.id), saved.servers.map(\.id))
    }
}
