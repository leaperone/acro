import Bonsplit
import Foundation
import Testing
@testable import AcroDesktop

@MainActor
@Suite
struct TerminalPanesInteractionTests {
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
