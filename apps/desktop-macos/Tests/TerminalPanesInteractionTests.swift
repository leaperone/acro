import AppKit
import Bonsplit
import Foundation
import SwiftUI
import Testing
@testable import AcroDesktop

@MainActor
@Suite
struct TerminalPanesInteractionTests {
    @Test
    func failedSessionRemovalKeepsTheSelectedTab() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let fallback = makeSession(id: UUID().uuidString)
        let closing = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [fallback.id, closing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                Issue.record("refresh must not run after a failed mutation")
                throw RpcError(message: "unexpected refresh")
            },
            rpcProvider: { _, _ in throw RpcError(message: "remove failed") }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [fallback, closing],
            focus: []
        )
        let server = ServerEntry(
            localId: key.serverId,
            name: "Server",
            deviceId: "device",
            token: "token",
            pub: "public-key",
            endpoints: []
        )
        let model = WorkbenchModel(
            hub: RuntimeHub(entries: [.init(server: server, connection: runtime)])
        )
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: [fallback.id, closing.id],
                selectedSessionId: closing.id
            ))
        )
        model.selectedSessionId = closing.id
        let paneController = try #require(model.currentTerminalPaneController)
        let bonsplitController = paneController.controller
        let initialFocusRequest = model.terminalFocusRequest

        await model.terminateSession(closing, on: runtime)

        #expect(paneController.controller === bonsplitController)
        #expect(paneController.controller.allTabIds.count == 2)
        #expect(paneController.focusedSessionId == closing.id)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [fallback.id, closing.id])
        #expect(model.selectedSessionId == closing.id)
        #expect(model.terminalFocusRequest == initialFocusRequest)
        #expect(model.errorMessage == "remove failed")
    }

    @Test
    func closingBackgroundTabDoesNotReactivateTheTerminal() throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let active = makeSession(id: UUID().uuidString)
        let background = makeSession(id: UUID().uuidString)
        let (_, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [active.id, background.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [active, background]
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: [active.id, background.id],
                selectedSessionId: active.id
            ))
        )
        model.selectedSessionId = active.id
        let paneController = try #require(model.currentTerminalPaneController)
        let initialFocusRequest = model.terminalFocusRequest
        let initialFlashToken = model.flashToken

        model.closeTab(background.id, workspaceId: key.resourceId, serverId: key.serverId)

        #expect(paneController.focusedSessionId == active.id)
        #expect(model.selectedSessionId == active.id)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [active.id])
        #expect(model.terminalFocusRequest == initialFocusRequest)
        #expect(model.flashToken == initialFlashToken)
    }

    @Test
    func closingSelectedLiveTabImmediatelyActivatesFallbackWithoutControllerRebuild() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let fallback = makeSession(id: UUID().uuidString)
        let closing = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [fallback.id, closing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let refreshGate = RefreshSnapshotGate()
        var rpcCalls: [(method: String, sessionId: String?)] = []
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                try await refreshGate.wait()
            },
            rpcProvider: { method, params in
                rpcCalls.append((method, params["sessionId"] as? String))
                return method == "session.claimFocus" ? ["claimed": true] : [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [fallback, closing],
            focus: []
        )
        let server = ServerEntry(
            localId: key.serverId,
            name: "Server",
            deviceId: "device",
            token: "token",
            pub: "public-key",
            endpoints: []
        )
        let model = WorkbenchModel(
            hub: RuntimeHub(entries: [.init(server: server, connection: runtime)])
        )
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: [fallback.id, closing.id],
                selectedSessionId: closing.id
            ))
        )
        model.selectedSessionId = closing.id
        let paneController = try #require(model.currentTerminalPaneController)
        let bonsplitController = paneController.controller
        let initialFocusRequest = model.terminalFocusRequest

        let termination = Task { await model.terminateSession(closing, on: runtime) }
        while !refreshGate.isWaiting { await Task.yield() }
        for _ in 0..<20 where !rpcCalls.contains(where: {
            $0.method == "session.claimFocus" && $0.sessionId == fallback.id
        }) {
            await Task.yield()
        }

        #expect(paneController.controller === bonsplitController)
        #expect(paneController.controller.allTabIds.count == 1)
        #expect(paneController.focusedSessionId == fallback.id)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [fallback.id])
        #expect(model.selectedSessionId == fallback.id)
        #expect(model.terminalFocusRequest > initialFocusRequest)
        #expect(rpcCalls.contains(where: {
            $0.method == "session.claimFocus" && $0.sessionId == fallback.id
        }))

        refreshGate.resume(returning: .init(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: workspace.id,
                name: workspace.name,
                sessionIds: [fallback.id],
                createdAt: workspace.createdAt,
                layout: nil,
                layoutRev: nil
            )],
            sessions: [fallback],
            focus: []
        ))
        await termination.value
        model.reconcileLayoutState()

        #expect(paneController.controller === bonsplitController)
        #expect(paneController.focusedSessionId == fallback.id)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [fallback.id])
    }

    @Test
    func restoresPersistedTopologyAndDividerPosition() throws {
        let fixture = makeSplitFixture()
        let paneController = try #require(fixture.model.currentTerminalPaneController)

        guard case .split(let split) = paneController.controller.treeSnapshot() else {
            Issue.record("expected restored split tree")
            return
        }

        #expect(abs(split.dividerPosition - 0.35) < 0.0001)
        #expect(paneController.controller.allPaneIds.count == 2)
        #expect(paneController.controller.allTabIds.count == 3)
    }

    @Test
    func tabReorderPersistsThroughBonsplitDelegate() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessions = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: sessions))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let livePane = try #require(paneController.controller.allPaneIds.first)
        let firstTab = try #require(paneController.controller.tabs(inPane: livePane).first)

        #expect(paneController.controller.reorderTab(firstTab.id, toIndex: 3))
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [
            sessions[1], sessions[2], sessions[0],
        ])
    }

    @Test
    func incrementalSessionTitleRefreshesTheRenderedTab() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessionId = UUID().uuidString
        let session = Session(
            id: sessionId,
            cwd: "/tmp",
            command: "zsh",
            cols: 80,
            rows: 24,
            createdAt: "2026-07-27T00:00:00Z",
            alive: true,
            exitCode: nil,
            title: nil,
            agent: nil
        )
        let (runtime, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [sessionId],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [session]
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [sessionId]))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let pane = try #require(paneController.controller.allPaneIds.first)
        #expect(paneController.controller.tabs(inPane: pane).first?.title == "tmp")

        let hostingView = NSHostingView(rootView: TerminalPanesView(model: model, runtime: runtime))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let previousKeyWindow = NSApp.keyWindow
        defer {
            window.orderOut(nil)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))

        let revision = runtime.snapshotRevision
        #expect(runtime.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": sessionId, "title": "vim"]
        ))
        try await Task.sleep(for: .milliseconds(100))

        #expect(runtime.snapshotRevision == revision)
        #expect(model.currentTerminalPaneController === paneController)
        #expect(paneController.controller.tabs(inPane: pane).first?.title == "vim")
    }

    @Test
    func switchingToBackgroundWorkspaceAppliesItsPendingTitle() async throws {
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        let workspaces = [
            Workspace(
                id: "workspace-a", name: "A", sessionIds: [sessionA],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
            Workspace(
                id: "workspace-b", name: "B", sessionIds: [sessionB],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
        ]
        let sessions = [sessionA, sessionB].map {
            Session(
                id: $0, cwd: "/tmp", command: "zsh", cols: 80, rows: 24,
                createdAt: "2026-07-27T00:00:00Z", alive: true, exitCode: nil,
                title: nil, agent: nil
            )
        }
        let (runtime, hub) = makeRuntimeFixture(workspaces: workspaces, sessions: sessions)
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = "server"
        model.selectedWorkspaceId = workspaces[0].id
        for (workspace, session) in zip(workspaces, sessions) {
            model.workspaceLayouts[ScopedResourceID(
                serverId: "server", resourceId: workspace.id
            )] = WorkspaceTerminalLayout(
                root: .pane(PaneTabGroup(sessionIds: [session.id]))
            )
        }
        let keyB = ScopedResourceID(serverId: "server", resourceId: workspaces[1].id)
        let controllerB = try #require(model.terminalPaneControllers[keyB])
        let paneB = try #require(controllerB.controller.allPaneIds.first)

        let hostingView = NSHostingView(rootView: TerminalPanesView(model: model, runtime: runtime))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let previousKeyWindow = NSApp.keyWindow
        defer {
            window.orderOut(nil)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(runtime.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": sessionB, "title": "ssh prod"]
        ))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllerB.controller.tabs(inPane: paneB).first?.title == "tmp")

        model.selectedWorkspaceId = workspaces[1].id
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.currentTerminalPaneController === controllerB)
        #expect(controllerB.controller.tabs(inPane: paneB).first?.title == "ssh prod")
    }

    @Test
    func switchingBetweenEmptyMetadataControllersStillRefreshesTheNewController() async throws {
        let workspaces = [
            Workspace(
                id: "workspace-a", name: "A", sessionIds: [],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
            Workspace(
                id: "workspace-b", name: "B", sessionIds: [],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
        ]
        let (runtime, hub) = makeRuntimeFixture(workspaces: workspaces, sessions: [])
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = "server"
        model.selectedWorkspaceId = workspaces[0].id
        let missingA = UUID().uuidString
        let missingB = UUID().uuidString
        for (workspace, sessionId) in zip(workspaces, [missingA, missingB]) {
            model.workspaceLayouts[ScopedResourceID(
                serverId: "server", resourceId: workspace.id
            )] = WorkspaceTerminalLayout(
                root: .pane(PaneTabGroup(sessionIds: [sessionId]))
            )
        }
        let keyB = ScopedResourceID(serverId: "server", resourceId: workspaces[1].id)
        let controllerB = try #require(model.terminalPaneControllers[keyB])
        let paneB = try #require(controllerB.controller.allPaneIds.first)
        let tabB = try #require(controllerB.controller.tabs(inPane: paneB).first)
        controllerB.controller.updateTab(tabB.id, title: "stale")

        let hostingView = NSHostingView(rootView: TerminalPanesView(model: model, runtime: runtime))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let previousKeyWindow = NSApp.keyWindow
        defer {
            window.orderOut(nil)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))

        model.selectedWorkspaceId = workspaces[1].id
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.currentTerminalPaneController === controllerB)
        #expect(controllerB.controller.tabs(inPane: paneB).first?.title == "终端")
    }

    @Test
    func mouseDragBetweenRenderedTabsReordersAndPersists() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessions = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        let runtime = RuntimeConnection()
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: sessions,
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: sessions.map { id in
                Session(
                    id: id,
                    cwd: "/tmp",
                    command: "zsh",
                    cols: 80,
                    rows: 24,
                    createdAt: "2026-07-27T00:00:00Z",
                    alive: true,
                    exitCode: nil,
                    title: nil,
                    agent: nil
                )
            },
            focus: []
        )
        let server = ServerEntry(
            localId: key.serverId,
            name: "Server",
            deviceId: "device",
            token: "token",
            pub: "public-key",
            endpoints: []
        )
        let hub = RuntimeHub(entries: [.init(server: server, connection: runtime)])
        let model = WorkbenchModel(hub: hub)
        model.restoreLayoutIfNeeded()
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.setLeftSidebarPresentation(.wide)
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: sessions))
        )

        let hostingView = NSHostingView(rootView: WorkbenchView(model: model, runtime: runtime))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let previousKeyWindow = NSApp.keyWindow
        defer {
            window.orderOut(nil)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(!window.isMovable)

        let tabViews = renderedTabItemHitRegions(in: hostingView)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        #expect(tabViews.count == sessions.count)
        let source = try #require(tabViews.first)
        let destination = try #require(tabViews.last)
        let sourcePoint = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let destinationPoint = destination.convert(
            NSPoint(x: destination.bounds.maxX - 2, y: destination.bounds.midY),
            to: nil
        )

        for event in [
            try mouseEvent(.leftMouseDown, at: sourcePoint, in: window),
            try mouseEvent(.leftMouseDragged, at: destinationPoint, in: window),
            try mouseEvent(.leftMouseUp, at: destinationPoint, in: window),
        ] {
            NSApp.sendEvent(event)
        }

        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [
            sessions[1], sessions[2], sessions[0],
        ])
    }

    @Test
    func crossPaneMovePersistsThroughBonsplitDelegate() throws {
        let fixture = makeSplitFixture()
        let paneController = try #require(fixture.model.currentTerminalPaneController)
        guard case .split(let split) = paneController.controller.treeSnapshot(),
              case .pane(let left) = split.first,
              case .pane(let right) = split.second,
              let leftPaneId = UUID(uuidString: left.id),
              let rightPaneId = UUID(uuidString: right.id)
        else {
            Issue.record("expected two live panes")
            return
        }
        let leftPane = PaneID(id: leftPaneId)
        let rightPane = PaneID(id: rightPaneId)
        let movedTab = try #require(paneController.controller.tabs(inPane: leftPane).first)

        #expect(paneController.controller.moveTab(movedTab.id, toPane: rightPane, atIndex: 0))
        let layout = try #require(fixture.model.workspaceLayouts[fixture.key])
        #expect(layout.root?.panes.map(\.sessionIds) == [
            [fixture.sessions[1]],
            [fixture.sessions[0], fixture.sessions[2]],
        ])
    }

    @Test
    func dividerDragPersistsOnlyTheFinalRatio() throws {
        let fixture = makeSplitFixture()
        let paneController = try #require(fixture.model.currentTerminalPaneController)
        guard case .split(let split) = paneController.controller.treeSnapshot(),
              let splitId = UUID(uuidString: split.id)
        else {
            Issue.record("expected live split")
            return
        }

        paneController.controller.noteDividerDragSession(true)
        #expect(paneController.controller.setDividerPosition(0.7, forSplit: splitId))
        guard case .split(let duringDrag)? = fixture.model.workspaceLayouts[fixture.key]?.root else {
            Issue.record("expected persisted split")
            return
        }
        #expect(abs(duringDrag.ratio - 0.35) < 0.0001)

        paneController.controller.noteDividerDragSession(false)
        guard case .split(let persisted)? = fixture.model.workspaceLayouts[fixture.key]?.root else {
            Issue.record("expected persisted split")
            return
        }
        #expect(abs(persisted.ratio - 0.7) < 0.0001)
    }

    @Test
    func fileDropTargetsTheSelectedSessionInTheDestinationPane() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessions = [UUID().uuidString, UUID().uuidString]
        var receivedKey: ScopedResourceID?
        var receivedURLs: [URL] = []
        let paneController = TerminalPaneController(
            model: model,
            key: key,
            layout: WorkspaceTerminalLayout(
                root: .pane(PaneTabGroup(
                    sessionIds: sessions,
                    selectedSessionId: sessions[1]
                ))
            ),
            trafficLightClearance: false,
            fileDropHandler: { key, urls in
                receivedKey = key
                receivedURLs = urls
                return true
            }
        )
        let pane = try #require(paneController.controller.allPaneIds.first)
        let urls = [URL(fileURLWithPath: "/tmp/a b")]

        #expect(paneController.controller.onFileDrop?(urls, pane) == true)
        #expect(receivedKey == ScopedResourceID(
            serverId: key.serverId,
            resourceId: sessions[1]
        ))
        #expect(receivedURLs == urls)
    }

    @Test
    func removingWorkspaceLayoutDeactivatesAndReleasesItsController() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
        )
        let paneController = try #require(model.terminalPaneControllers[key])

        model.workspaceLayouts.removeValue(forKey: key)

        #expect(model.terminalPaneControllers[key] == nil)
        #expect(paneController.controller.isInteractive == false)
        #expect(paneController.controller.delegate == nil)
        #expect(paneController.controller.onFileDrop == nil)
    }

    @Test
    func replacingExternalLayoutDeactivatesThePreviousControllerGeneration() throws {
        let fixture = makeSplitFixture()
        let paneController = try #require(fixture.model.currentTerminalPaneController)
        let previousController = paneController.controller

        fixture.model.workspaceLayouts[fixture.key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: fixture.sessions))
        )

        #expect(paneController.controller !== previousController)
        #expect(previousController.isInteractive == false)
        #expect(previousController.delegate == nil)
        #expect(previousController.onTabCloseRequest == nil)
        #expect(previousController.onFileDrop == nil)
    }

    @Test
    func sidebarPresentationOnlyReservesTrafficLightSpaceWhenHidden() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
        )
        let paneController = try #require(model.currentTerminalPaneController)

        #expect(paneController.controller.configuration.appearance.tabBarLeadingInset == 0)
        model.setLeftSidebarPresentation(.compact)
        #expect(paneController.controller.configuration.appearance.tabBarLeadingInset == 0)
        model.setLeftSidebarPresentation(.hidden)
        #expect(paneController.controller.configuration.appearance.tabBarLeadingInset == 80)
        model.setLeftSidebarPresentation(.wide)
        #expect(paneController.controller.configuration.appearance.tabBarLeadingInset == 0)
    }

    @Test
    func productionFileDropFailsClosedWithoutAnAuthenticatedRuntime() {
        let model = WorkbenchModel(hub: RuntimeHub())

        #expect(model.handleTerminalFileDrop(
            [URL(fileURLWithPath: "/tmp/file")],
            sessionKey: ScopedResourceID(serverId: "missing", resourceId: "session"),
            workspaceId: "workspace"
        ) == false)
    }

    private func makeSplitFixture() -> (
        model: WorkbenchModel,
        key: ScopedResourceID,
        sessions: [String]
    ) {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessions = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        let left = PaneTabGroup(sessionIds: Array(sessions.prefix(2)))
        let right = PaneTabGroup(sessionIds: [sessions[2]])
        let root = TerminalLayoutNode.split(SplitNode(
            direction: .horizontal,
            ratio: 0.35,
            first: .pane(left),
            second: .pane(right)
        ))
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: root,
            focusedPaneId: left.id
        )
        return (model, key, sessions)
    }
}

@MainActor
private func renderedTabItemHitRegions(in root: NSView) -> [NSView] {
    var candidates: [NSView] = []
    if root is BonsplitTabItemHitRegionProviding, !root.isHidden, root.alphaValue > 0 {
        candidates.append(root)
    }
    for subview in root.subviews {
        candidates.append(contentsOf: renderedTabItemHitRegions(in: subview))
    }
    return candidates.filter { candidate in
        let frame = candidate.convert(candidate.bounds, to: nil)
        return !candidates.contains { other in
            other !== candidate && frame.contains(other.convert(other.bounds, to: nil))
        }
    }
}

@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    in window: NSWindow
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))
}

@MainActor
private func makeRuntimeFixture(
    workspaces: [Workspace],
    sessions: [Session]
) -> (runtime: RuntimeConnection, hub: RuntimeHub) {
    let runtime = RuntimeConnection()
    runtime.commitRefreshSnapshot(
        workspaceGroups: [],
        workspaces: workspaces,
        sessions: sessions,
        focus: []
    )
    let server = ServerEntry(
        localId: "server",
        name: "Server",
        deviceId: "device",
        token: "token",
        pub: "public-key",
        endpoints: []
    )
    return (runtime, RuntimeHub(entries: [.init(server: server, connection: runtime)]))
}

private func makeSession(id: String) -> Session {
    Session(
        id: id,
        cwd: "/tmp",
        command: "zsh",
        cols: 80,
        rows: 24,
        createdAt: "2026-07-27T00:00:00Z",
        alive: true,
        exitCode: nil,
        title: nil,
        agent: nil
    )
}

@MainActor
private final class RefreshSnapshotGate {
    private var continuation: CheckedContinuation<RuntimeConnection.RefreshSnapshot, Error>?
    private(set) var isWaiting = false

    func wait() async throws -> RuntimeConnection.RefreshSnapshot {
        isWaiting = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(returning snapshot: RuntimeConnection.RefreshSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
