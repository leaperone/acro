import XCTest

@testable import AcroDesktop

final class PanelModelLifecycleTests: XCTestCase {
    @MainActor
    func testFileBrowserRejectsLateCwdFromPreviousSession() async {
        var cwdRequests: [String: CheckedContinuation<String?, Error>] = [:]
        var listedPaths: [String] = []
        let model = FileBrowserModel(operations: .init(
            cwd: { _, sessionId in
                try await withCheckedThrowingContinuation { cwdRequests[sessionId] = $0 }
            },
            list: { _, path in
                listedPaths.append(path)
                return [Self.fileEntry(path: "\(path)/file.txt")]
            },
            read: { _, path in Self.fileContent(path: path) },
            search: { _, _, _ in [] }
        ))
        let runtime = RuntimeConnection()

        let first = Task { await model.follow(sessionId: "first", runtime: runtime) }
        await waitUntil { cwdRequests["first"] != nil }

        let second = Task { await model.follow(sessionId: "second", runtime: runtime) }
        await waitUntil { cwdRequests["second"] != nil }
        cwdRequests.removeValue(forKey: "second")?.resume(returning: "/second")
        await second.value
        await waitUntil { model.rootNodes != nil }

        cwdRequests.removeValue(forKey: "first")?.resume(returning: "/first")
        await first.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.rootPath, "/second")
        XCTAssertEqual(listedPaths, ["/second"])
    }

    @MainActor
    func testFileBrowserSessionSwitchClearsVisibleStateImmediately() async {
        let model = FileBrowserModel(operations: .init(
            cwd: { _, _ in nil },
            list: { _, path in [Self.fileEntry(path: "\(path)/file.txt")] },
            read: { _, path in Self.fileContent(path: path) },
            search: { _, _, _ in [] }
        ))
        let runtime = RuntimeConnection()

        model.beginFollow(sessionId: "first", runtime: runtime)
        model.sync(root: "/first", runtime: runtime)
        await waitUntil { model.rootNodes != nil }
        model.openPreview("/first/file.txt")
        await waitUntil { model.preview != nil }

        model.beginFollow(sessionId: "second", runtime: runtime)

        XCTAssertEqual(model.rootPath, "")
        XCTAssertNil(model.rootNodes)
        XCTAssertNil(model.selectedPath)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isRootLoading)
        XCTAssertFalse(model.isPreviewLoading)
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testFileBrowserCancelAllRejectsLateRootResult() async {
        var release: CheckedContinuation<[FileEntry], Error>?
        var listCount = 0
        let model = FileBrowserModel(operations: .init(
            cwd: { _, _ in "/root" },
            list: { _, _ in
                listCount += 1
                if listCount == 1 {
                    return try await withCheckedThrowingContinuation { release = $0 }
                }
                return [Self.fileEntry(path: "/root/reloaded.txt")]
            },
            read: { _, path in Self.fileContent(path: path) },
            search: { _, _, _ in [] }
        ))
        let runtime = RuntimeConnection()

        model.beginFollow(sessionId: "session", runtime: runtime)
        model.sync(root: "/root", runtime: runtime)
        await waitUntil { release != nil }
        XCTAssertTrue(model.isRootLoading)

        model.cancelAll()
        XCTAssertFalse(model.isRootLoading)
        release?.resume(returning: [Self.fileEntry(path: "/root/file.txt")])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(model.rootNodes)

        await model.follow(sessionId: "session", runtime: runtime)
        await waitUntil { model.rootNodes != nil }
        XCTAssertEqual(model.rootNodes?.map(\.path), ["/root/reloaded.txt"])
    }

    @MainActor
    func testGitPanelRejectsLateCwdFromPreviousSession() async {
        var cwdRequests: [String: CheckedContinuation<String?, Error>] = [:]
        let model = GitPanelModel(operations: .init(
            cwd: { _, sessionId in
                try await withCheckedThrowingContinuation { cwdRequests[sessionId] = $0 }
            },
            status: { _, root in
                GitStatus(isRepo: true, root: root, branch: (root as NSString).lastPathComponent, files: [])
            },
            diff: { _, _ in GitDiffResult(diff: "", truncated: false) }
        ))
        let runtime = RuntimeConnection()

        let first = Task { await model.follow(sessionId: "first", runtime: runtime) }
        await waitUntil { cwdRequests["first"] != nil }

        let second = Task { await model.follow(sessionId: "second", runtime: runtime) }
        await waitUntil { cwdRequests["second"] != nil }
        cwdRequests.removeValue(forKey: "second")?.resume(returning: "/second")
        await second.value
        await waitUntil { model.status?.branch == "second" }

        cwdRequests.removeValue(forKey: "first")?.resume(returning: "/first")
        await first.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.status?.root, "/second")
        XCTAssertEqual(model.status?.branch, "second")
    }

    @MainActor
    func testGitPanelCancelAllRejectsLateStatus() async {
        var release: CheckedContinuation<GitStatus, Error>?
        let model = GitPanelModel(operations: .init(
            cwd: { _, _ in nil },
            status: { _, _ in
                try await withCheckedThrowingContinuation { release = $0 }
            },
            diff: { _, _ in GitDiffResult(diff: "", truncated: false) }
        ))
        let runtime = RuntimeConnection()

        model.sync(root: "/repo", runtime: runtime)
        await waitUntil { release != nil }
        XCTAssertTrue(model.isLoading)

        model.cancelAll()
        XCTAssertFalse(model.isLoading)
        release?.resume(returning: GitStatus(isRepo: true, root: "/repo", branch: "main", files: []))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(model.status)
    }

    @MainActor
    func testPortsCancelAllRejectsLateResult() async {
        var release: CheckedContinuation<[PortListener], Error>?
        let model = PortsPanelModel(operations: .init(load: { _ in
            try await withCheckedThrowingContinuation { release = $0 }
        }))
        let runtime = RuntimeConnection()

        model.loadIfNeeded(runtime: runtime)
        await waitUntil { release != nil }
        XCTAssertTrue(model.isLoading)

        model.cancelAll()
        XCTAssertFalse(model.isLoading)
        release?.resume(returning: [PortListener(port: 8790, address: "127.0.0.1", pid: 1, process: "node")])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(model.listeners)
    }

    @MainActor
    func testPortsReconnectClearsStaleListenersAndReloads() async {
        var loads: [CheckedContinuation<[PortListener], Error>] = []
        let model = PortsPanelModel(operations: .init(load: { _ in
            try await withCheckedThrowingContinuation { loads.append($0) }
        }))
        let runtime = RuntimeConnection()

        model.loadIfNeeded(runtime: runtime)
        await waitUntil { loads.count == 1 }
        loads.removeFirst().resume(returning: [
            PortListener(port: 8790, address: "127.0.0.1", pid: 1, process: "old")
        ])
        await waitUntil { model.listeners?.first?.process == "old" }

        model.connectionChanged(runtime: runtime, connected: false)
        XCTAssertNil(model.listeners)

        model.connectionChanged(runtime: runtime, connected: true)
        await waitUntil { loads.count == 1 }
        loads.removeFirst().resume(returning: [
            PortListener(port: 8790, address: "127.0.0.1", pid: 2, process: "new")
        ])
        await waitUntil { model.listeners?.first?.process == "new" }
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not met", file: file, line: line)
    }

    private static func fileEntry(path: String) -> FileEntry {
        FileEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: "file",
            size: 1,
            mtimeMs: 0
        )
    }

    private static func fileContent(path: String) -> FileContent {
        FileContent(
            path: path,
            kind: "text",
            text: "content",
            base64: nil,
            mime: "text/plain",
            size: 7,
            truncated: false
        )
    }
}
