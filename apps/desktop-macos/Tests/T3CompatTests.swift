import Foundation
import XCTest

@testable import AcroDesktop

final class T3CompatTests: XCTestCase {
    func testNodeVersionFloorMatchesT3Package() {
        XCTAssertFalse(T3NodeVersion("v22.15.0")!.supportsT3)
        XCTAssertTrue(T3NodeVersion("v22.16.0")!.supportsT3)
        XCTAssertFalse(T3NodeVersion("23.10.9")!.supportsT3)
        XCTAssertTrue(T3NodeVersion("23.11.0")!.supportsT3)
        XCTAssertFalse(T3NodeVersion("24.9.0")!.supportsT3)
        XCTAssertTrue(T3NodeVersion("24.10.0")!.supportsT3)
        XCTAssertTrue(T3NodeVersion("25.0.0")!.supportsT3)
        XCTAssertNil(T3NodeVersion("not-node"))
    }

    func testShellEnvironmentIgnoresProfileNoise() {
        let output = """
        noisy profile output
        __ACRO_T3_PATH_START__
        /opt/homebrew/bin:/usr/bin
        __ACRO_T3_PATH_END__
        __ACRO_T3_SSH_AUTH_SOCK_START__
        /tmp/agent.sock
        __ACRO_T3_SSH_AUTH_SOCK_END__
        """
        XCTAssertEqual(T3ShellEnvironment.parse(output)["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(T3ShellEnvironment.parse(output)["SSH_AUTH_SOCK"], "/tmp/agent.sock")
    }

    func testNavigationAllowsOnlyTheT3Origin() {
        let origin = URL(string: "http://127.0.0.1:4888")!
        XCTAssertEqual(
            T3NavigationPolicy.disposition(
                for: URL(string: "http://127.0.0.1:4888/thread/1")!,
                origin: origin
            ),
            .embedded
        )
        XCTAssertEqual(
            T3NavigationPolicy.disposition(for: URL(string: "https://example.com")!, origin: origin),
            .external
        )
        XCTAssertEqual(
            T3NavigationPolicy.disposition(for: URL(string: "file:///tmp/token")!, origin: origin),
            .blocked
        )
    }

    func testCookiePolicyKeepsOnlyTheLoopbackRootCookie() throws {
        let matching = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "t3-session",
            .value: "secret",
        ]))
        let wrongHost = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "t3-session",
            .value: "secret",
        ]))
        XCTAssertEqual(
            T3CookiePolicy.cookies(
                for: URL(string: "http://127.0.0.1:4888")!,
                from: [wrongHost, matching]
            ).map(\.name),
            ["t3-session"]
        )
    }

    func testLoopbackOriginRejectsRemoteAndMissingPorts() {
        XCTAssertTrue(T3CompatManager.isLoopback(URL(string: "http://127.0.0.1:4888")!))
        XCTAssertTrue(T3CompatManager.isLoopback(URL(string: "http://localhost:4888")!))
        XCTAssertFalse(T3CompatManager.isLoopback(URL(string: "https://127.0.0.1:4888")!))
        XCTAssertFalse(T3CompatManager.isLoopback(URL(string: "http://192.168.1.2:4888")!))
        XCTAssertFalse(T3CompatManager.isLoopback(URL(string: "http://127.0.0.1")!))
    }

    func testAvailablePortIsUsableAndNonPrivileged() throws {
        XCTAssertTrue((1024...65_535).contains(try T3CompatManager.availablePort()))
    }
}
