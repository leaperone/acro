import AppKit
import Bonsplit
import Foundation
import SwiftUI
import Testing
@testable import AcroDesktop

@MainActor
@Suite(.serialized)
struct TerminalPanesInteractionTests {
    @Test
    func appBootstrapsMinimalBonsplitPresentation() {
        let defaults = UserDefaults.standard
        let key = "workspacePresentationMode"
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        _ = AcroApp()

        #expect(defaults.string(forKey: key) == "minimal")
    }

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
        var removalAttempts = 0
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                Issue.record("refresh must not run after a failed mutation")
                throw RpcError(message: "unexpected refresh")
            },
            rpcProvider: { method, _ in
                if method == "session.remove" { removalAttempts += 1 }
                throw RpcError(message: "remove failed")
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

        await model.terminateSession(closing, on: runtime)

        #expect(paneController.controller === bonsplitController)
        #expect(paneController.controller.allTabIds.count == 2)
        #expect(paneController.focusedSessionId == closing.id)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [fallback.id, closing.id])
        #expect(model.selectedSessionId == closing.id)
        #expect(model.terminalFocusRequest == initialFocusRequest)
        #expect(model.errorMessage == "remove failed")
        #expect(removalAttempts == 1)

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [fallback, closing],
            focus: []
        )
        await Task.yield()
        #expect(removalAttempts == 1)
    }

    @Test
    func attachTransportExitKeepsAliveSessionLayoutAndCustomTitle() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let session = makeSession(id: UUID().uuidString)
        let (_, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [session.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [session]
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        var layout = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [session.id]))
        )
        let didSetTitle = layout.setCustomTitle("Build", for: session.id)
        #expect(didSetTitle)
        model.workspaceLayouts[key] = layout
        model.selectedSessionId = session.id
        let paneController = try #require(model.currentTerminalPaneController)

        let disposition = await model.terminalSurfaceExitDisposition(
            session.id,
            workspaceId: key.resourceId,
            serverId: key.serverId
        )
        #expect(disposition == .restartTransport)
        #expect(model.currentTerminalPaneController === paneController)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [session.id])
        #expect(model.workspaceLayouts[key]?.customTitlesBySessionId == [session.id: "Build"])
        #expect(model.selectedSessionId == session.id)
    }

    @Test
    func attachTransportExitDoesNotRestartAfterSessionEnds() async {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let session = makeSession(id: UUID().uuidString)
        let (runtime, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [session.id],
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
            root: .pane(PaneTabGroup(sessionIds: [session.id]))
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: runtime.workspaces,
            sessions: [],
            focus: []
        )

        let disposition = await model.terminalSurfaceExitDisposition(
            session.id,
            workspaceId: key.resourceId,
            serverId: key.serverId
        )
        #expect(disposition == .close)
        model.reconcileLayoutState()
        #expect(model.workspaceLayouts[key]?.root == nil)
    }

    @Test
    func attachTransportExitRefreshesBeforeRestarting() async {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let session = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [session.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        var refreshCount = 0
        let runtime = RuntimeConnection(refreshSnapshotProvider: {
            refreshCount += 1
            return .init(
                workspaceGroups: [],
                workspaces: [workspace],
                sessions: [],
                focus: []
            )
        })
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [session],
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
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [session.id]))
        )

        let disposition = await model.terminalSurfaceExitDisposition(
            session.id,
            workspaceId: key.resourceId,
            serverId: key.serverId
        )

        #expect(refreshCount == 1)
        #expect(disposition == .close)
        model.reconcileLayoutState()
        #expect(model.workspaceLayouts[key]?.root == nil)
    }

    @Test
    func terminalSurfaceExitDispositionUsesRemoteSessionAsTheAuthority() {
        #expect(TerminalSurfaceExitDisposition.resolve(
            remoteSessionAlive: true
        ) == .restartTransport)
        #expect(TerminalSurfaceExitDisposition.resolve(
            remoteSessionAlive: false
        ) == .close)
    }

    @Test
    func terminalContentStateDoesNotTreatUnknownOrPendingAsEnded() {
        #expect(TerminalPaneContentState.resolve(
            hasSessionMapping: false,
            isTabLoading: true,
            snapshotLoaded: true,
            remoteSessionAlive: false
        ) == .creating)
        #expect(TerminalPaneContentState.resolve(
            hasSessionMapping: true,
            isTabLoading: false,
            snapshotLoaded: false,
            remoteSessionAlive: false
        ) == .connecting)
        #expect(TerminalPaneContentState.resolve(
            hasSessionMapping: true,
            isTabLoading: false,
            snapshotLoaded: true,
            remoteSessionAlive: true
        ) == .active)
        #expect(TerminalPaneContentState.resolve(
            hasSessionMapping: true,
            isTabLoading: false,
            snapshotLoaded: true,
            remoteSessionAlive: false
        ) == .ended)
    }

    @Test
    func splitKeepsOneLoadingTabUntilCreatedSessionEntersTheSnapshot() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let existing = makeSession(id: UUID().uuidString)
        let created = makeSession(id: UUID().uuidString)
        let initialWorkspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [existing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let refreshGate = RefreshSnapshotGate()
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: { try await refreshGate.wait() },
            rpcProvider: { method, _ in
                if method == "session.create" { return try jsonObject(created) }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [initialWorkspace],
            sessions: [existing],
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
            root: .pane(PaneTabGroup(sessionIds: [existing.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let controller = paneController.controller
        let originalPane = try #require(controller.allPaneIds.first)

        paneController.split(.horizontal)

        let createdPane = try #require(controller.allPaneIds.first { $0 != originalPane })
        let placeholder = try #require(controller.tabs(inPane: createdPane).first)
        #expect(placeholder.isLoading)
        #expect(paneController.sessionId(for: placeholder.id) == nil)

        #expect(await waitUntil { refreshGate.isWaiting })
        let pendingTab = try #require(controller.tabs(inPane: createdPane).first)
        #expect(pendingTab.id == placeholder.id)
        #expect(pendingTab.isLoading)
        #expect(paneController.sessionId(for: pendingTab.id) == created.id)
        #expect(!runtime.sessions.contains(where: { $0.id == created.id }))

        refreshGate.resume(returning: .init(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [existing.id, created.id],
                createdAt: initialWorkspace.createdAt,
                layout: nil,
                layoutRev: nil
            )],
            sessions: [existing, created],
            focus: []
        ))
        #expect(await waitUntil {
            controller.tabs(inPane: createdPane).first?.isLoading == false
        })

        let resolvedTab = try #require(controller.tabs(inPane: createdPane).first)
        #expect(paneController.controller === controller)
        #expect(resolvedTab.id == placeholder.id)
        #expect(!resolvedTab.isLoading)
        #expect(paneController.sessionId(for: resolvedTab.id) == created.id)
    }

    @Test
    func failedSplitCreationRemovesTheLoadingPlaceholderAndEmptyPane() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let existing = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [existing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let runtime = RuntimeConnection(
            rpcProvider: { _, _ in throw RpcError(message: "create failed") }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [existing],
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
            root: .pane(PaneTabGroup(sessionIds: [existing.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)

        paneController.split(.horizontal)
        #expect(paneController.controller.allPaneIds.count == 2)
        #expect(paneController.controller.allTabIds.count == 2)
        #expect(paneController.controller.allPaneIds.contains { pane in
            paneController.controller.tabs(inPane: pane).contains { $0.isLoading }
        })

        #expect(await waitUntil { model.errorMessage != nil })

        #expect(model.errorMessage == "create failed")
        #expect(paneController.controller.allPaneIds.count == 1)
        #expect(paneController.controller.allTabIds.count == 1)
        #expect(paneController.controller.allPaneIds.allSatisfy { pane in
            paneController.controller.tabs(inPane: pane).allSatisfy { !$0.isLoading }
        })
    }

    @Test
    func closingPendingCreationDoesNotResurrectItsPlaceholder() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let existing = makeSession(id: UUID().uuidString)
        let created = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [existing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let createGate = RpcResultGate()
        var removedSessionIds: [String] = []
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                .init(
                    workspaceGroups: [],
                    workspaces: [workspace],
                    sessions: [existing],
                    focus: []
                )
            },
            rpcProvider: { method, params in
                if method == "session.create" { return try await createGate.wait() }
                if method == "session.remove", let sessionId = params["sessionId"] as? String {
                    removedSessionIds.append(sessionId)
                }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [existing],
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
            root: .pane(PaneTabGroup(sessionIds: [existing.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)

        paneController.split(.horizontal)
        #expect(await waitUntil { createGate.isWaiting })
        let placeholder = try #require(paneController.controller.allPaneIds
            .flatMap { paneController.controller.tabs(inPane: $0) }
            .first { $0.isLoading })
        #expect(paneController.controller.closeTab(placeholder.id))

        createGate.resume(returning: try jsonObject(created))
        #expect(await waitUntil { !removedSessionIds.isEmpty })
        model.reconcileLayoutState()

        #expect(removedSessionIds == [created.id])
        #expect(!paneController.controller.allTabIds.contains(placeholder.id))
        #expect(!runtime.sessions.contains(where: { $0.id == created.id }))
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [existing.id])
        #expect(paneController.controller.allPaneIds.flatMap {
            paneController.controller.tabs(inPane: $0)
        }.allSatisfy { !$0.isLoading })
    }

    @Test
    func closingBoundPendingCreationRetriesFailedRemovalWithoutResurrection() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let existing = makeSession(id: UUID().uuidString)
        let created = makeSession(id: UUID().uuidString)
        let initialWorkspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [existing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let createdWorkspace = Workspace(
            id: key.resourceId,
            name: initialWorkspace.name,
            sessionIds: [existing.id, created.id],
            createdAt: initialWorkspace.createdAt,
            layout: nil,
            layoutRev: nil
        )
        let refreshGate = RefreshSnapshotGate()
        var refreshCount = 0
        var removalAttempts = 0
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                refreshCount += 1
                if refreshCount == 1 { return try await refreshGate.wait() }
                return .init(
                    workspaceGroups: [],
                    workspaces: [initialWorkspace],
                    sessions: [existing],
                    focus: []
                )
            },
            rpcProvider: { method, _ in
                if method == "session.create" { return try jsonObject(created) }
                if method == "session.remove" {
                    removalAttempts += 1
                    if removalAttempts == 1 { throw RpcError(message: "remove failed") }
                }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [initialWorkspace],
            sessions: [existing],
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
            root: .pane(PaneTabGroup(sessionIds: [existing.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)

        paneController.split(.horizontal)
        #expect(await waitUntil { refreshGate.isWaiting })
        let placeholder = try #require(paneController.controller.allPaneIds
            .flatMap { paneController.controller.tabs(inPane: $0) }
            .first { paneController.sessionId(for: $0.id) == created.id })
        model.requestKillTab(created.id, for: key)
        #expect(!paneController.controller.allTabIds.contains(placeholder.id))

        refreshGate.resume(returning: .init(
            workspaceGroups: [],
            workspaces: [createdWorkspace],
            sessions: [existing, created],
            focus: []
        ))
        #expect(await waitUntil { removalAttempts >= 1 })

        #expect(removalAttempts == 1)
        #expect(model.errorMessage == "remove failed")
        #expect(!runtime.sessions.contains(where: { $0.id == created.id }))
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [existing.id])

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [createdWorkspace],
            sessions: [existing, created],
            focus: []
        )
        #expect(await waitUntil { removalAttempts >= 2 && refreshCount >= 2 })

        #expect(removalAttempts == 2)
        #expect(refreshCount == 2)
        #expect(!runtime.sessions.contains(where: { $0.id == created.id }))
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [existing.id])
        #expect(!paneController.controller.allTabIds.contains(placeholder.id))
    }

    @Test
    func pendingRemovalSurvivesAnOlderSnapshotUntilTheRpcIsAcknowledged() async {
        let session = makeSession(id: UUID().uuidString)
        let firstRemoval = RpcResultGate()
        var removalAttempts = 0
        var refreshCount = 0
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                refreshCount += 1
                return .init(workspaceGroups: [], workspaces: [], sessions: [], focus: [])
            },
            rpcProvider: { method, _ in
                guard method == "session.remove" else { return [:] }
                removalAttempts += 1
                if removalAttempts == 1 { return try await firstRemoval.wait() }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [session],
            focus: []
        )

        let removal = Task {
            try? await runtime.requestPersistentSessionRemoval(session.id)
        }
        #expect(await waitUntil { firstRemoval.isWaiting })
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [],
            focus: []
        )
        firstRemoval.resume(throwing: RpcError(message: "remove failed"))
        await removal.value

        #expect(removalAttempts == 1)
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [],
            focus: []
        )
        #expect(await waitUntil { removalAttempts >= 2 && refreshCount >= 1 })

        #expect(removalAttempts == 2)
        #expect(refreshCount == 1)
        #expect(runtime.sessions.isEmpty)
    }

    @Test
    func acknowledgedRemovalIgnoresSnapshotsStartedBeforeTheRpcSucceeded() async {
        let session = makeSession(id: UUID().uuidString)
        let olderRefresh = RefreshSnapshotGate()
        var refreshCount = 0
        var removalAttempts = 0
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                refreshCount += 1
                if refreshCount == 1 { return try await olderRefresh.wait() }
                if refreshCount == 2 {
                    return .init(
                        workspaceGroups: [], workspaces: [], sessions: [session], focus: []
                    )
                }
                return .init(workspaceGroups: [], workspaces: [], sessions: [], focus: [])
            },
            rpcProvider: { method, _ in
                if method == "session.remove" { removalAttempts += 1 }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [session],
            focus: []
        )

        let olderRefreshTask = Task { await runtime.refresh() }
        #expect(await waitUntil { olderRefresh.isWaiting })
        let removal = Task {
            try? await runtime.requestPersistentSessionRemoval(session.id)
        }
        #expect(await waitUntil { removalAttempts == 1 })
        olderRefresh.resume(returning: .init(
            workspaceGroups: [],
            workspaces: [],
            sessions: [],
            focus: []
        ))
        _ = await olderRefreshTask.value
        await removal.value

        #expect(removalAttempts == 1)
        #expect(refreshCount == 2)
        #expect(!runtime.sessions.contains(where: { $0.id == session.id }))

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [session],
            focus: []
        )
        #expect(await waitUntil { removalAttempts >= 2 && refreshCount >= 3 })

        #expect(removalAttempts == 2)
        #expect(refreshCount == 3)
        #expect(runtime.sessions.isEmpty)
    }

    @Test
    func restoringTopologyCancelsAndCleansUpPendingCreation() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let existing = makeSession(id: UUID().uuidString)
        let created = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [existing.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let createGate = RpcResultGate()
        var removedSessionIds: [String] = []
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                .init(
                    workspaceGroups: [],
                    workspaces: [workspace],
                    sessions: [existing],
                    focus: []
                )
            },
            rpcProvider: { method, params in
                if method == "session.create" { return try await createGate.wait() }
                if method == "session.remove", let sessionId = params["sessionId"] as? String {
                    removedSessionIds.append(sessionId)
                }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [existing],
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
            root: .pane(PaneTabGroup(sessionIds: [existing.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)

        paneController.split(.horizontal)
        #expect(await waitUntil { createGate.isWaiting })
        paneController.update(layout: WorkspaceTerminalLayout(), trafficLightClearance: false)

        createGate.resume(returning: try jsonObject(created))
        #expect(await waitUntil { !removedSessionIds.isEmpty })

        #expect(removedSessionIds == [created.id])
        #expect(!runtime.sessions.contains(where: { $0.id == created.id }))
        #expect(paneController.controller.allPaneIds.flatMap {
            paneController.controller.tabs(inPane: $0)
        }.allSatisfy { !$0.isLoading })
    }

    @Test
    func ghosttyCloseActionUsesTheAppTerminationPath() {
        let view = AcroTerminalNSView(
            serverId: UUID().uuidString,
            sessionId: UUID().uuidString,
            command: "true"
        )
        var requestCount = 0
        view.onCloseRequest = { requestCount += 1 }

        view.requestClose()

        #expect(requestCount == 1)
    }

    @Test
    func liveTransportExitKeepsTheCachedSurfaceViewForRestart() async throws {
        let serverId = UUID().uuidString
        let sessionId = UUID().uuidString
        let cache = TerminalSurfaceCache.shared
        let view = cache.view(serverId: serverId, sessionId: sessionId, command: "true")
        view.onClose = { .restartTransport }
        defer { cache.evict(serverId: serverId, sessionId: sessionId) }

        view.surfaceDidRequestClose()
        #expect(cache.view(serverId: serverId, sessionId: sessionId, command: "true") === view)
        try await Task.sleep(for: .milliseconds(600))
        #expect(cache.view(serverId: serverId, sessionId: sessionId, command: "true") === view)
    }

    @Test
    func authoritativeTerminalExitEvictsTheCachedSurfaceView() async throws {
        let serverId = UUID().uuidString
        let sessionId = UUID().uuidString
        let cache = TerminalSurfaceCache.shared
        let view = cache.view(serverId: serverId, sessionId: sessionId, command: "true")
        view.onClose = { .close }

        view.surfaceDidRequestClose()
        try await Task.sleep(for: .milliseconds(20))
        let replacement = cache.view(serverId: serverId, sessionId: sessionId, command: "true")
        defer { cache.evict(serverId: serverId, sessionId: sessionId) }
        #expect(replacement !== view)
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
    func backgroundAgentAttentionIsUnreadUntilTheTabIsSelected() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let foreground = makeSession(
            id: UUID().uuidString,
            agentState: "working",
            agentUpdatedAt: "2026-07-27T00:00:00Z"
        )
        let background = makeSession(
            id: UUID().uuidString,
            agentState: "working",
            agentUpdatedAt: "2026-07-27T00:00:00Z"
        )
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [foreground.id, background.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let (runtime, hub) = makeRuntimeFixture(
            workspaces: [workspace],
            sessions: [foreground, background]
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: [foreground.id, background.id],
                selectedSessionId: foreground.id
            ))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let pane = try #require(paneController.controller.allPaneIds.first)
        let backgroundTab = try #require(
            paneController.controller.tabs(inPane: pane).first(where: {
                paneController.sessionId(for: $0.id) == background.id
            })
        )
        let foregroundTab = try #require(
            paneController.controller.tabs(inPane: pane).first(where: {
                paneController.sessionId(for: $0.id) == foreground.id
            })
        )
        #expect(backgroundTab.showsNotificationBadge == false)

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

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [foreground, makeSession(
                id: background.id,
                agentState: "waiting",
                agentUpdatedAt: "2026-07-27T00:01:00Z"
            )],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == true)

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [foreground, makeSession(id: background.id)],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == false)

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [foreground, makeSession(
                id: background.id,
                agentState: "error",
                agentUpdatedAt: "2026-07-27T00:03:00Z"
            )],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == true)

        paneController.controller.selectTab(backgroundTab.id)
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == false)

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [foreground, makeSession(
                id: background.id,
                agentState: "waiting",
                agentUpdatedAt: "2026-07-27T00:01:00Z"
            )],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == false)

        paneController.controller.selectTab(foregroundTab.id)
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [foreground, makeSession(
                id: background.id,
                agentState: "error",
                agentUpdatedAt: "2026-07-27T00:04:00Z"
            )],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(paneController.controller.tab(backgroundTab.id)?.showsNotificationBadge == true)
    }

    @Test
    func initialAttentionBadgesOnlyBackgroundTabs() throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let selected = makeSession(id: UUID().uuidString, agentState: "error")
        let background = makeSession(id: UUID().uuidString, agentState: "done")
        let (_, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [selected.id, background.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [selected, background]
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: [selected.id, background.id],
                selectedSessionId: selected.id
            ))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let pane = try #require(paneController.controller.allPaneIds.first)
        let tabs = paneController.controller.tabs(inPane: pane)
        let selectedTab = try #require(tabs.first(where: {
            paneController.sessionId(for: $0.id) == selected.id
        }))
        let backgroundTab = try #require(tabs.first(where: {
            paneController.sessionId(for: $0.id) == background.id
        }))

        #expect(selectedTab.showsNotificationBadge == false)
        #expect(backgroundTab.showsNotificationBadge == true)
    }

    @Test
    func hiddenWorkspaceKeepsAttentionUnreadUntilItBecomesVisible() async throws {
        let serverId = "server"
        let workspaceA = Workspace(
            id: "workspace-a",
            name: "A",
            sessionIds: ["session-a"],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let workspaceB = Workspace(
            id: "workspace-b",
            name: "B",
            sessionIds: ["session-b"],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        let sessionA = makeSession(id: "session-a", agentState: "working")
        let sessionB = makeSession(id: "session-b", agentState: "working")
        let (runtime, hub) = makeRuntimeFixture(
            workspaces: [workspaceA, workspaceB],
            sessions: [sessionA, sessionB]
        )
        let model = WorkbenchModel(hub: hub)
        model.restoreLayoutIfNeeded()
        model.selectedServerId = serverId
        model.selectedWorkspaceId = workspaceA.id
        for workspace in [workspaceA, workspaceB] {
            model.workspaceLayouts[ScopedResourceID(
                serverId: serverId,
                resourceId: workspace.id
            )] = WorkspaceTerminalLayout(
                root: .pane(PaneTabGroup(
                    sessionIds: workspace.sessionIds,
                    selectedSessionId: workspace.sessionIds.first
                ))
            )
        }
        let keyB = ScopedResourceID(serverId: serverId, resourceId: workspaceB.id)

        let hostingView = NSHostingView(rootView: WorkbenchView(model: model, runtime: runtime))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
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

        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspaceA, workspaceB],
            sessions: [sessionA, makeSession(
                id: sessionB.id,
                agentState: "waiting",
                agentUpdatedAt: "2026-07-27T00:01:00Z"
            )],
            focus: []
        )
        try await Task.sleep(for: .milliseconds(150))
        let unreadControllerB = try #require(model.terminalPaneControllers[keyB])
        let unreadTabB = try #require(unreadControllerB.controller.allTabIds.first(where: {
            unreadControllerB.sessionId(for: $0) == sessionB.id
        }))
        #expect(unreadControllerB.controller.tab(unreadTabB)?.showsNotificationBadge == true)

        model.selectedWorkspaceId = workspaceB.id
        try await Task.sleep(for: .milliseconds(100))
        let visibleControllerB = try #require(model.terminalPaneControllers[keyB])
        let visibleTabB = try #require(visibleControllerB.controller.allTabIds.first(where: {
            visibleControllerB.sessionId(for: $0) == sessionB.id
        }))
        #expect(visibleControllerB.controller.tab(visibleTabB)?.showsNotificationBadge == false)
    }

    @Test
    func switchingToBackgroundWorkspaceAppliesItsPendingTitle() async throws {
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        let sessionB2 = UUID().uuidString
        let workspaces = [
            Workspace(
                id: "workspace-a", name: "A", sessionIds: [sessionA],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
            Workspace(
                id: "workspace-b", name: "B", sessionIds: [sessionB, sessionB2],
                createdAt: "2026-07-27T00:00:00Z", layout: nil, layoutRev: nil
            ),
        ]
        let sessions = [sessionA, sessionB, sessionB2].map {
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
        model.workspaceLayouts[ScopedResourceID(
            serverId: "server", resourceId: workspaces[0].id
        )] = WorkspaceTerminalLayout(root: .pane(PaneTabGroup(sessionIds: [sessionA])))
        model.workspaceLayouts[ScopedResourceID(
            serverId: "server", resourceId: workspaces[1].id
        )] = WorkspaceTerminalLayout(root: .pane(PaneTabGroup(sessionIds: [sessionB, sessionB2])))
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

        let renderedTabs = renderedTabItemHitRegions(in: hostingView)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let destination = try #require(renderedTabs.last)
        let destinationPoint = destination.convert(
            NSPoint(x: destination.bounds.midX, y: destination.bounds.midY),
            to: nil
        )
        for event in [
            try mouseEvent(.leftMouseDown, at: destinationPoint, in: window),
            try mouseEvent(.leftMouseUp, at: destinationPoint, in: window),
        ] {
            NSApp.sendEvent(event)
        }

        #expect(model.workspaceLayouts[keyB]?.focusedSessionId == sessionB2)
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
    func mouseClickDragAndSplitButtonUseTheirFullRenderedHitTargets() async throws {
        let defaults = UserDefaults.standard
        let presentationKey = "workspacePresentationMode"
        let previousPresentation = defaults.object(forKey: presentationKey)
        defaults.set("minimal", forKey: presentationKey)
        defer {
            if let previousPresentation {
                defaults.set(previousPresentation, forKey: presentationKey)
            } else {
                defaults.removeObject(forKey: presentationKey)
            }
        }

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
        let window = WindowDragSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
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
        #expect(hostingView.safeAreaInsets.top == 0)
        #expect(!window.isMovableByWindowBackground)
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()

        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: sessions,
                selectedSessionId: sessions[1]
            ))
        )
        window.contentView?.layoutSubtreeIfNeeded()
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(!window.isMovable)
        #expect(hostingView.safeAreaInsets.top == 0)
        window.setContentSize(NSSize(width: 880, height: 480))
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(hostingView.safeAreaInsets.top == 0)

        let tabViews = renderedTabItemHitRegions(in: hostingView)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        #expect(tabViews.count == sessions.count)
        let source = try #require(tabViews.first)
        let destination = try #require(tabViews.last)
        let contentTop = hostingView.convert(hostingView.bounds, to: nil).maxY
        let tabTop = tabViews.map { $0.convert($0.bounds, to: nil).maxY }.max()
        #expect(abs(try #require(tabTop) - contentTop) <= 1)

        let sourcePoint = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let destinationPoint = destination.convert(
            NSPoint(x: destination.bounds.maxX - 2, y: destination.bounds.midY),
            to: nil
        )

        for event in [
            try mouseEvent(.leftMouseDown, at: destinationPoint, in: window),
            try mouseEvent(.leftMouseUp, at: destinationPoint, in: window),
        ] {
            NSApp.sendEvent(event)
        }

        #expect(model.workspaceLayouts[key]?.focusedSessionId == sessions[2])

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

        defaults.set("standard", forKey: presentationKey)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        let splitRightPoint = NSPoint(
            x: hostingView.convert(hostingView.bounds, to: nil).maxX - 45,
            y: destinationPoint.y
        )
        for event in [
            try mouseEvent(.leftMouseDown, at: splitRightPoint, in: window),
            try mouseEvent(.leftMouseUp, at: splitRightPoint, in: window),
        ] {
            NSApp.sendEvent(event)
        }

        #expect(model.currentTerminalPaneController?.controller.allPaneIds.count == 2)
        #expect(window.performDragCallCount == 0)
    }

    @Test
    func explicitWindowDragUsesNativeSessionAndRestoresImmovableWindow() throws {
        let window = WindowDragSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let dragHandle = WindowDragNSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = dragHandle
        window.isMovable = false
        let event = try mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)

        dragHandle.mouseDown(with: event)

        #expect(!dragHandle.mouseDownCanMoveWindow)
        #expect(window.performDragCallCount == 0)
        #expect(!window.isMovable)

        dragHandle.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            at: NSPoint(x: 22, y: 21),
            in: window
        ))
        #expect(window.performDragCallCount == 0)

        dragHandle.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            at: NSPoint(x: 25, y: 20),
            in: window
        ))

        #expect(window.performDragCallCount == 1)
        #expect(window.receivedDragEvent === event)
        #expect(window.wasMovableDuringPerformDrag)
        #expect(!window.isMovable)

        let doubleClick = try mouseEvent(
            .leftMouseDown,
            at: NSPoint(x: 20, y: 20),
            in: window,
            clickCount: 2
        )
        dragHandle.mouseDown(with: doubleClick)

        #expect(window.zoomCallCount == 1)
        #expect(window.performDragCallCount == 1)
        #expect(!window.isMovable)
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
    func terminalTabsUseCmuxActionLaneFade() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let effect = try #require(
            paneController.controller.configuration.appearance.splitButtonBackdropEffect
        )

        #expect(effect.style == .translucentChrome)
        #expect(effect.fadeWidth == 99.75)
        #expect(effect.contentFadeWidth == 28.875)
        #expect(effect.solidWidth == 23.875)
        #expect(effect.solidSurfaceWidthAdjustment == -80)
        #expect(effect.separatorFadeWidth == 99.75)
        #expect(effect.fadeRampStartFraction == 0.60)
        #expect(effect.leadingOpacity == 0)
        #expect(effect.trailingOpacity == 0.8625)
        #expect(effect.contentOcclusionFraction == 0.6875)
        #expect(effect.masksTabContent)
    }

    @Test
    func terminalTabsExposeOnlySupportedContextActions() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
        )
        let configuration = try #require(
            model.currentTerminalPaneController?.controller.configuration
        )

        #expect(configuration.allowsTabContextMenu)
        #expect(configuration.allowedTabContextActions == [
            .rename,
            .clearName,
            .closeToLeft,
            .closeToRight,
            .closeOthers,
            .moveToLeftPane,
            .moveToRightPane,
            .toggleZoom,
            .toggleFullWidthTab,
        ])
    }

    @Test
    func closeOtherContextActionRequestsOneBatchConfirmation() throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let sessions = (0..<3).map { _ in makeSession(id: UUID().uuidString) }
        let (_, hub) = makeRuntimeFixture(
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: sessions.map(\.id),
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: sessions
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedServerId = key.serverId
        model.selectedWorkspaceId = key.resourceId
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(
                sessionIds: sessions.map(\.id),
                selectedSessionId: sessions[1].id
            ))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let pane = try #require(paneController.controller.allPaneIds.first)
        let anchor = try #require(paneController.controller.tabs(inPane: pane).dropFirst().first)

        paneController.splitTabBar(
            paneController.controller,
            didRequestTabContextAction: .closeOthers,
            for: anchor,
            inPane: pane
        )

        #expect(Set(model.pendingSessionTerminationRequest?.sessionIds ?? []) == [
            sessions[0].id,
            sessions[2].id,
        ])
        #expect(model.pendingSessionTerminationRequest?.key == key)
        #expect(paneController.controller.allTabIds.count == 3)
    }

    @Test
    func secondCloseRequestCannotReplaceThePendingTransaction() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let first = makeSession(id: UUID().uuidString)
        let second = makeSession(id: UUID().uuidString)
        let remainingWorkspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [second.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        var removedSessionIds: [String] = []
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                .init(
                    workspaceGroups: [],
                    workspaces: [remainingWorkspace],
                    sessions: [second],
                    focus: []
                )
            },
            rpcProvider: { method, params in
                if method == "session.remove", let sessionId = params["sessionId"] as? String {
                    removedSessionIds.append(sessionId)
                }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [first.id, second.id],
                createdAt: remainingWorkspace.createdAt,
                layout: nil,
                layoutRev: nil
            )],
            sessions: [first, second],
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
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [first.id, second.id]))
        )

        model.requestSessionTermination(first, for: key)
        model.requestSessionTermination(second, for: key)

        let request = try #require(model.takePendingSessionTerminationRequest())
        #expect(request.sessionIds == [first.id])
        await model.confirmSessionTermination(request)
        #expect(removedSessionIds == [first.id])
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [second.id])
    }

    @Test
    func pendingCloseKeepsItsOriginServerAndCancelAllowsANewRequest() throws {
        let firstKey = ScopedResourceID(serverId: "server-a", resourceId: "workspace")
        let secondKey = ScopedResourceID(serverId: "server-b", resourceId: "workspace")
        let first = makeSession(id: UUID().uuidString)
        let second = makeSession(id: UUID().uuidString)
        let firstRuntime = RuntimeConnection()
        firstRuntime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: firstKey.resourceId,
                name: "A",
                sessionIds: [first.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [first],
            focus: []
        )
        let secondRuntime = RuntimeConnection()
        secondRuntime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: secondKey.resourceId,
                name: "B",
                sessionIds: [second.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: nil,
                layoutRev: nil
            )],
            sessions: [second],
            focus: []
        )
        let model = WorkbenchModel(hub: RuntimeHub(entries: [
            .init(server: ServerEntry(
                localId: firstKey.serverId,
                name: "A",
                deviceId: "device-a",
                token: "token-a",
                pub: "public-key-a",
                endpoints: []
            ), connection: firstRuntime),
            .init(server: ServerEntry(
                localId: secondKey.serverId,
                name: "B",
                deviceId: "device-b",
                token: "token-b",
                pub: "public-key-b",
                endpoints: []
            ), connection: secondRuntime),
        ]))

        model.requestSessionTermination(first, for: firstKey)
        model.requestSessionTermination(second, for: secondKey)
        #expect(model.pendingSessionTerminationRequest == PendingSessionTerminationRequest(
            key: firstKey,
            sessionIds: [first.id]
        ))

        model.cancelPendingSessionTermination()
        #expect(model.pendingSessionTerminationRequest == nil)
        model.requestSessionTermination(second, for: secondKey)
        #expect(model.pendingSessionTerminationRequest == PendingSessionTerminationRequest(
            key: secondKey,
            sessionIds: [second.id]
        ))
    }

    @Test
    func batchTerminationClosesOnlySuccessfulSessionsAndRefreshesOnce() async throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let removed = makeSession(id: UUID().uuidString)
        let failed = makeSession(id: UUID().uuidString)
        let workspace = Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [removed.id, failed.id],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
        var refreshCount = 0
        var removedSessionIds: [String] = []
        let runtime = RuntimeConnection(
            refreshSnapshotProvider: {
                refreshCount += 1
                return .init(
                    workspaceGroups: [],
                    workspaces: [Workspace(
                        id: workspace.id,
                        name: workspace.name,
                        sessionIds: [failed.id],
                        createdAt: workspace.createdAt,
                        layout: nil,
                        layoutRev: nil
                    )],
                    sessions: [failed],
                    focus: []
                )
            },
            rpcProvider: { method, params in
                let sessionId = params["sessionId"] as? String
                if method == "session.remove", sessionId == failed.id {
                    throw RpcError(message: "remove failed")
                }
                if method == "session.remove", let sessionId {
                    removedSessionIds.append(sessionId)
                }
                return [:]
            }
        )
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [workspace],
            sessions: [removed, failed],
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
            root: .pane(PaneTabGroup(sessionIds: [removed.id, failed.id]))
        )

        await model.terminateSessions([removed, failed], on: runtime)

        #expect(removedSessionIds == [removed.id])
        #expect(refreshCount == 1)
        #expect(model.workspaceLayouts[key]?.root?.sessionIds == [failed.id])
        #expect(model.errorMessage == "remove failed")
    }

    @Test
    func contextActionMovesTabToAdjacentPaneAndPersists() throws {
        let fixture = makeSplitFixture()
        let paneController = try #require(fixture.model.currentTerminalPaneController)
        let panes = paneController.controller.allPaneIds
        let left = try #require(panes.first)
        let right = try #require(paneController.controller.adjacentPane(to: left, direction: .right))
        let tab = try #require(paneController.controller.tabs(inPane: left).first)
        let sessionId = try #require(paneController.sessionId(for: tab.id))

        paneController.splitTabBar(
            paneController.controller,
            didRequestTabContextAction: .moveToRightPane,
            for: tab,
            inPane: left
        )

        #expect(paneController.controller.paneId(containing: tab.id) == right)
        #expect(fixture.model.workspaceLayouts[fixture.key]?.root?.pane(withId: right.id.uuidString)?
            .sessionIds.contains(sessionId) == true)
    }

    @Test
    func terminalThemeChromeUpdatesEveryCachedWorkspace() throws {
        let model = WorkbenchModel(hub: RuntimeHub())
        let keys = [
            ScopedResourceID(serverId: "server", resourceId: "one"),
            ScopedResourceID(serverId: "server", resourceId: "two"),
        ]
        model.selectedServerId = "server"
        model.selectedWorkspaceId = keys[0].resourceId
        for key in keys {
            model.workspaceLayouts[key] = WorkspaceTerminalLayout(
                root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
            )
        }

        let opaque = TerminalChromeAppearance(red: 0x12, green: 0x34, blue: 0x56, opacity: 1)
        model.applyTerminalChromeAppearance(opaque)
        let lateKey = ScopedResourceID(serverId: "server", resourceId: "three")
        model.workspaceLayouts[lateKey] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [UUID().uuidString]))
        )

        #expect(model.terminalChromeAppearance == opaque)
        for key in keys + [lateKey] {
            let appearance = try #require(
                model.terminalPaneControllers[key]?.controller.configuration.appearance
            )
            #expect(appearance.chromeColors.backgroundHex == "#123456")
            #expect(appearance.chromeColors.tabBarBackgroundHex == "#00000000")
            #expect(appearance.chromeColors.splitButtonBackdropHex == "#00000000")
            #expect(appearance.chromeColors.paneBackgroundHex == "#00000000")
            #expect(appearance.usesSharedBackdrop)
            #expect(appearance.splitButtonBackdropEffect?.fadeWidth == 99.75)
        }

        let translucent = TerminalChromeAppearance(
            red: 0x12,
            green: 0x34,
            blue: 0x56,
            opacity: 0.5
        )
        model.applyTerminalChromeAppearance(translucent)

        for key in keys + [lateKey] {
            let appearance = try #require(
                model.terminalPaneControllers[key]?.controller.configuration.appearance
            )
            #expect(!appearance.usesSharedBackdrop)
            #expect(appearance.chromeColors.tabBarBackgroundHex == appearance.chromeColors.backgroundHex)
            #expect(appearance.chromeColors.tabBarBackgroundHex != "#00000000")
        }
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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
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
private final class WindowDragSpyWindow: NSWindow {
    private(set) var performDragCallCount = 0
    private(set) var receivedDragEvent: NSEvent?
    private(set) var wasMovableDuringPerformDrag = false
    private(set) var zoomCallCount = 0

    override func performDrag(with event: NSEvent) {
        performDragCallCount += 1
        receivedDragEvent = event
        wasMovableDuringPerformDrag = isMovable
    }

    override func zoom(_ sender: Any?) {
        zoomCallCount += 1
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
    in window: NSWindow,
    clickCount: Int = 1
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
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

private func makeSession(
    id: String,
    agentState: String? = nil,
    agentUpdatedAt: String = "2026-07-27T00:00:00Z"
) -> Session {
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
        agent: agentState.map {
            AgentSession(
                provider: "codex",
                state: $0,
                providerSessionId: nil,
                codexHome: nil,
                accountFingerprint: nil,
                managed: true,
                interrupted: false,
                updatedAt: agentUpdatedAt
            )
        }
    )
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
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

@MainActor
private final class RpcResultGate {
    private var continuation: CheckedContinuation<Any, Error>?
    private(set) var isWaiting = false

    func wait() async throws -> Any {
        isWaiting = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(returning value: Any) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
