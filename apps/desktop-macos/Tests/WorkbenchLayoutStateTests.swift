import XCTest
@testable import AcroDesktop

private struct LegacyWorkbenchLayoutSnapshot: Encodable {
    let selectedServerId: String?
    let selectedWorkspaceId: String?
    let workspaceLayouts: [String: WorkspaceTerminalLayout]
    let leftSidebarVisible: Bool
    let inspectorVisible: Bool
}

final class WorkbenchLayoutStateTests: XCTestCase {
    func testTabAdoptSelectCloseAndSplit() throws {
        var layout = WorkspaceTerminalLayout()

        // adopt 建窗格,后续 adopt 变标签
        layout.adopt("one")
        layout.adopt("two")
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])
        XCTAssertEqual(layout.focusedSessionId, "two")

        // 已存在的会话 adopt 只切选中
        layout.adopt("one")
        XCTAssertEqual(layout.focusedSessionId, "one")
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])

        // 分屏出第二个窗格
        let firstPaneId = layout.focusedPane!.id
        layout.split(fromPane: firstPaneId, direction: .horizontal, newSessionId: "three")
        XCTAssertEqual(layout.root?.panes.count, 2)
        XCTAssertEqual(layout.focusedSessionId, "three")

        // 关标签:窗格空了会被摘除,焦点回退
        layout.removeTab("three")
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.focusedSessionId, "one")
    }

    func testMoveTabBetweenPanesAndToSplit() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("one")
        layout.adopt("two")
        let sourcePaneId = layout.focusedPane!.id
        layout.split(fromPane: sourcePaneId, direction: .horizontal, newSessionId: "three")
        let targetPaneId = layout.focusedPane!.id

        // 移动标签到另一窗格的指定位置
        layout.moveTab("one", toPane: targetPaneId, at: 0)
        XCTAssertEqual(layout.root?.pane(withId: targetPaneId)?.sessionIds, ["one", "three"])
        XCTAssertEqual(layout.root?.pane(withId: sourcePaneId)?.sessionIds, ["two"])
        XCTAssertEqual(layout.focusedSessionId, "one")

        // 拖到边缘生成新分屏,新窗格在前半
        layout.moveTabToSplit("three", ofPane: sourcePaneId, direction: .vertical, newPaneFirst: true)
        XCTAssertEqual(layout.root?.panes.count, 3)
        XCTAssertEqual(layout.focusedSessionId, "three")

        // 源窗格因搬空被摘除
        layout.moveTab("two", toPane: layout.focusedPane!.id, at: nil)
        XCTAssertEqual(layout.root?.panes.count, 2)
        XCTAssertEqual(layout.root?.pane(withId: sourcePaneId), nil)
    }

    func testDirectionalPaneNavigation() throws {
        // 左 | (右上 / 右下) 的布局
        var layout = WorkspaceTerminalLayout()
        layout.adopt("left")
        let leftPaneId = layout.focusedPane!.id
        layout.split(fromPane: leftPaneId, direction: .horizontal, newSessionId: "rightTop")
        let rightTopPaneId = layout.focusedPane!.id
        layout.split(fromPane: rightTopPaneId, direction: .vertical, newSessionId: "rightBottom")
        let rightBottomPaneId = layout.focusedPane!.id

        // 从右下:向上 → 右上;向左 → 左
        XCTAssertEqual(layout.paneId(toward: .up), rightTopPaneId)
        XCTAssertEqual(layout.paneId(toward: .left), leftPaneId)
        XCTAssertNil(layout.paneId(toward: .right))
        XCTAssertNil(layout.paneId(toward: .down))

        // 从左:向右 → 投影重叠相同时距离近者;右上/右下与左均全高重叠?
        // 左窗格全高,右上/右下各半高,重叠各为自身高度,取重叠更大者之一(相等取先者)
        layout.focusedPaneId = leftPaneId
        let right = layout.paneId(toward: .right)
        XCTAssertTrue(right == rightTopPaneId || right == rightBottomPaneId)

        // 从右上:向下 → 右下
        layout.focusedPaneId = rightTopPaneId
        XCTAssertEqual(layout.paneId(toward: .down), rightBottomPaneId)
    }

    func testAdjacentTabNavigationCrossesSplitPanes() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("left-one")
        layout.adopt("left-two")
        let leftPaneId = try XCTUnwrap(layout.focusedPane?.id)
        layout.split(fromPane: leftPaneId, direction: .horizontal, newSessionId: "right-one")
        let rightPaneId = try XCTUnwrap(layout.focusedPane?.id)
        layout.adopt("right-two")

        layout.selectTab("left-one", inPane: leftPaneId)
        var target = try XCTUnwrap(layout.adjacentTab(offset: 1))
        XCTAssertEqual(target.sessionId, "left-two")
        XCTAssertEqual(target.paneId, leftPaneId)

        layout.selectTab("left-two", inPane: leftPaneId)
        target = try XCTUnwrap(layout.adjacentTab(offset: 1))
        XCTAssertEqual(target.sessionId, "right-one")
        XCTAssertEqual(target.paneId, rightPaneId)

        layout.selectTab("right-one", inPane: rightPaneId)
        target = try XCTUnwrap(layout.adjacentTab(offset: -1))
        XCTAssertEqual(target.sessionId, "left-two")
        XCTAssertEqual(target.paneId, leftPaneId)

        layout.selectTab("right-two", inPane: rightPaneId)
        target = try XCTUnwrap(layout.adjacentTab(offset: 1))
        XCTAssertEqual(target.sessionId, "left-one")
        XCTAssertEqual(target.paneId, leftPaneId)
    }

    func testNumberedTabNavigationUsesFocusedPaneAndNineMeansLast() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("left-one")
        layout.adopt("left-two")
        let leftPaneId = try XCTUnwrap(layout.focusedPane?.id)
        layout.split(fromPane: leftPaneId, direction: .horizontal, newSessionId: "right-one")
        let rightPaneId = try XCTUnwrap(layout.focusedPane?.id)
        layout.adopt("right-two")

        layout.selectTab("left-one", inPane: leftPaneId)
        XCTAssertEqual(layout.tab(number: 1)?.sessionId, "left-one")
        XCTAssertEqual(layout.tab(number: 9)?.sessionId, "left-two")

        layout.selectTab("right-one", inPane: rightPaneId)
        XCTAssertEqual(layout.tab(number: 1)?.sessionId, "right-one")
        XCTAssertEqual(layout.tab(number: 9)?.sessionId, "right-two")
        XCTAssertNil(layout.tab(number: 8))
    }

    func testSamePaneReorder() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("a")
        layout.adopt("b")
        layout.adopt("c")
        let paneId = layout.focusedPane!.id

        // 向后拖:a 落到 c 的插入指示器处(index 2),应插到 c 前面
        layout.moveTab("a", toPane: paneId, at: 2)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["b", "a", "c"])

        // 向前拖:c 落到 b 的位置(index 0),插到 b 前面
        layout.moveTab("c", toPane: paneId, at: 0)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["c", "b", "a"])

        // 落回本窗格中心(index nil,反悔动作):不改顺序,只选中
        layout.selectTab("b", inPane: paneId)
        layout.moveTab("c", toPane: paneId, at: nil)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["c", "b", "a"])
        XCTAssertEqual(layout.focusedSessionId, "c")

        // 标签条空白 = 显式末尾下标:同窗格排到最后
        layout.moveTab("c", toPane: paneId, at: 3)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["b", "a", "c"])
    }

    func testPruneAndRoundTrip() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("one")
        layout.adopt("two")
        layout.split(fromPane: layout.focusedPane!.id, direction: .vertical, newSessionId: "three")

        // 失效会话被剪掉,空窗格塌缩,焦点自愈
        layout.prune(validSessionIds: ["one", "two"])
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])
        XCTAssertNotNil(layout.focusedSessionId)

        let snapshot = WorkbenchLayoutSnapshot(
            selectedServerId: "server",
            selectedWorkspaceId: "workspace",
            workspaceLayouts: [
                ScopedResourceID(serverId: "server", resourceId: "workspace"): layout,
            ],
            leftSidebarVisible: true,
            inspectorVisible: false
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data), snapshot)
    }

    func testSnapshotKeepsSameWorkspaceIdSeparateAcrossServers() throws {
        var first = WorkspaceTerminalLayout()
        first.adopt("session-a")
        var second = WorkspaceTerminalLayout()
        second.adopt("session-b")
        let firstKey = ScopedResourceID(serverId: "server-a", resourceId: "workspace")
        let secondKey = ScopedResourceID(serverId: "server-b", resourceId: "workspace")
        let snapshot = WorkbenchLayoutSnapshot(
            selectedServerId: "server-a",
            selectedWorkspaceId: "workspace",
            workspaceLayouts: [firstKey: first, secondKey: second],
            leftSidebarVisible: true,
            inspectorVisible: true
        )

        let decoded = try JSONDecoder().decode(
            WorkbenchLayoutSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.workspaceLayouts[firstKey]?.root?.sessionIds, ["session-a"])
        XCTAssertEqual(decoded.workspaceLayouts[secondKey]?.root?.sessionIds, ["session-b"])
    }

    func testLegacySnapshotScopesLayoutsToSelectedServer() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("session")
        let legacy = LegacyWorkbenchLayoutSnapshot(
            selectedServerId: "server-a",
            selectedWorkspaceId: "workspace",
            workspaceLayouts: ["workspace": layout],
            leftSidebarVisible: true,
            inspectorVisible: false
        )

        let decoded = try JSONDecoder().decode(
            WorkbenchLayoutSnapshot.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(
            decoded.workspaceLayouts[
                ScopedResourceID(serverId: "server-a", resourceId: "workspace")
            ],
            layout
        )
    }

    @MainActor
    func testWorkbenchModelSelectsLayoutWithinCurrentServer() throws {
        var first = WorkspaceTerminalLayout()
        first.adopt("session-a")
        var second = WorkspaceTerminalLayout()
        second.adopt("session-b")
        let model = WorkbenchModel(hub: RuntimeHub())
        model.workspaceLayouts = [
            ScopedResourceID(serverId: "server-a", resourceId: "workspace"): first,
            ScopedResourceID(serverId: "server-b", resourceId: "workspace"): second,
        ]
        model.selectedWorkspaceId = "workspace"

        model.selectedServerId = "server-a"
        XCTAssertEqual(model.currentLayout?.root?.sessionIds, ["session-a"])

        model.selectedServerId = "server-b"
        XCTAssertEqual(model.currentLayout?.root?.sessionIds, ["session-b"])
    }

    @MainActor
    func testInvalidSelectedServerDoesNotFallBackToAnotherRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-workbench-server-\(UUID().uuidString)")
        let file = root.appendingPathComponent("client.json")
        setenv("ACRO_CLIENT_CONFIG", file.path, 1)
        let pub = Data(repeating: 1, count: 32).base64EncodedString()
        let first = ServerEntry(
            localId: "server-a", name: "A", deviceId: "device-a", token: "token-a",
            pub: pub, endpoints: ["127.0.0.1:1"]
        )
        let second = ServerEntry(
            localId: "server-b", name: "B", deviceId: "device-b", token: "token-b",
            pub: pub, endpoints: ["127.0.0.1:2"]
        )
        ClientConfig(v: 2, servers: [first, second], active: first.id).save()
        let hub = RuntimeHub()
        hub.reload()
        defer {
            ClientConfig(v: 2, servers: [], active: nil).save()
            hub.reload()
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        let model = WorkbenchModel(hub: hub)
        let remainingRuntime = try XCTUnwrap(hub.connection(for: second.id))
        ServerDirectory.remove(first.id, hub: hub)

        XCTAssertNil(hub.connection(for: first.id))
        XCTAssertFalse(model.runtime === remainingRuntime)

        model.reconcileLayoutState()

        XCTAssertEqual(model.selectedServerId, second.id)
        XCTAssertTrue(model.runtime === remainingRuntime)
    }

    @MainActor
    func testTerminalCloseMutatesOriginServerAfterSelectionChanges() throws {
        var first = WorkspaceTerminalLayout()
        first.adopt("shared-session")
        var second = WorkspaceTerminalLayout()
        second.adopt("shared-session")
        second.adopt("server-b-only")
        let firstKey = ScopedResourceID(serverId: "server-a", resourceId: "workspace")
        let secondKey = ScopedResourceID(serverId: "server-b", resourceId: "workspace")
        let model = WorkbenchModel(hub: RuntimeHub())
        model.workspaceLayouts = [firstKey: first, secondKey: second]
        model.selectedServerId = "server-b"
        model.selectedWorkspaceId = "workspace"

        model.closeTab(
            "shared-session",
            workspaceId: "workspace",
            serverId: "server-a"
        )

        XCTAssertNil(model.workspaceLayouts[firstKey]?.root)
        XCTAssertEqual(
            model.workspaceLayouts[secondKey]?.root?.sessionIds,
            ["shared-session", "server-b-only"]
        )
        XCTAssertEqual(model.currentLayout?.focusedSessionId, "server-b-only")
    }

    @MainActor
    func testWorkspaceExpansionIsScopedToServer() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let firstKey = ScopedResourceID(serverId: "server-a", resourceId: "workspace")
        let secondKey = ScopedResourceID(serverId: "server-b", resourceId: "workspace")

        model.toggleWorkspace("workspace", serverId: "server-a")
        XCTAssertTrue(model.expandedWorkspaceIds.contains(firstKey))
        XCTAssertFalse(model.expandedWorkspaceIds.contains(secondKey))

        model.toggleWorkspace("workspace", serverId: "server-b")
        XCTAssertTrue(model.expandedWorkspaceIds.contains(firstKey))
        XCTAssertTrue(model.expandedWorkspaceIds.contains(secondKey))

        model.toggleWorkspace("workspace", serverId: "server-a")
        XCTAssertFalse(model.expandedWorkspaceIds.contains(firstKey))
        XCTAssertTrue(model.expandedWorkspaceIds.contains(secondKey))
    }

    @MainActor
    func testPendingDestructiveActionFailsClosedWhenOriginServerDisappears() async throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let session = Session(
            id: "shared-session",
            cwd: "/tmp",
            command: "zsh",
            cols: 80,
            rows: 24,
            createdAt: "2026-07-18T00:00:00Z",
            alive: true,
            exitCode: nil,
            title: nil
        )
        model.selectedServerId = "server-a"
        model.pendingSessionTermination = session
        model.selectedServerId = "server-b"

        await model.terminateSession(session)

        XCTAssertNil(model.pendingSessionTermination)
        XCTAssertEqual(model.errorMessage, "目标服务器已移除，操作已取消")
    }

    @MainActor
    func testTerminalSurfaceCacheSeparatesSameSessionIdAcrossServers() throws {
        let cache = TerminalSurfaceCache.shared
        let suffix = UUID().uuidString
        let serverA = "server-a-\(suffix)"
        let serverB = "server-b-\(suffix)"
        let sessionId = "session-\(suffix)"
        defer {
            cache.evict(serverId: serverA, sessionId: sessionId)
            cache.evict(serverId: serverB, sessionId: sessionId)
        }

        let first = cache.view(serverId: serverA, sessionId: sessionId, command: "attach-a")
        let second = cache.view(serverId: serverB, sessionId: sessionId, command: "attach-b")

        XCTAssertFalse(first === second)
        XCTAssertTrue(
            first === cache.view(serverId: serverA, sessionId: sessionId, command: "ignored")
        )
        XCTAssertNotEqual(
            AttachCommand.resolve(sessionId: sessionId, serverId: serverA),
            AttachCommand.resolve(sessionId: sessionId, serverId: serverB)
        )
    }
}
