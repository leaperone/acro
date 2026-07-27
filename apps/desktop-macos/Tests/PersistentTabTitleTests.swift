import Foundation
import Bonsplit
import Testing
@testable import AcroDesktop

@Suite
struct PersistentTabTitleTests {
    @Test
    func layoutRoundTripPreservesCustomTitles() throws {
        let data = Data(#"{"root":null,"focusedPaneId":null,"customTitlesBySessionId":{"session":"Build"}}"#.utf8)
        let layout = try JSONDecoder().decode(WorkspaceTerminalLayout.self, from: data)
        let encoded = try JSONEncoder().encode(layout)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(
            object["customTitlesBySessionId"] as? [String: String]
                == ["session": "Build"]
        )
    }

    @Test
    func legacyLayoutDefaultsToNoCustomTitles() throws {
        let layout = try JSONDecoder().decode(
            WorkspaceTerminalLayout.self,
            from: Data(#"{"root":null,"focusedPaneId":null}"#.utf8)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any]
        )

        #expect(layout.customTitlesBySessionId.isEmpty)
        #expect(object["customTitlesBySessionId"] == nil)
    }

    @Test
    func customTitlesNormalizeFollowMovesAndCleanUp() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("one")
        layout.adopt("two")
        let firstPane = try #require(layout.focusedPane?.id)
        layout.split(fromPane: firstPane, direction: .horizontal, newSessionId: "three")
        let secondPane = try #require(layout.focusedPane?.id)

        let didSetBuild = layout.setCustomTitle("  Build  ", for: "one")
        #expect(didSetBuild)
        #expect(layout.customTitlesBySessionId["one"] == "Build")
        let didRepeatBuild = layout.setCustomTitle("Build", for: "one")
        #expect(!didRepeatBuild)

        layout.moveTab("one", toPane: secondPane, at: 0)
        #expect(layout.customTitlesBySessionId["one"] == "Build")

        let didSetLogs = layout.setCustomTitle("Logs", for: "three")
        #expect(didSetLogs)
        layout.prune(validSessionIds: ["one", "two"])
        #expect(layout.customTitlesBySessionId == ["one": "Build"])

        layout.removeTab("one")
        #expect(layout.customTitlesBySessionId.isEmpty)
        let didSetOrphan = layout.setCustomTitle("orphan", for: "missing")
        #expect(!didSetOrphan)
    }

    @MainActor
    @Test
    func customTitleOverridesOscAndClearRevealsLatestOscWithoutRebuild() throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let session = makeSession(id: "session", cwd: "/repo", title: "vim")
        let runtime = RuntimeConnection()
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [makeWorkspace(key: key, sessionId: session.id)],
            sessions: [session],
            focus: []
        )
        let model = makeModel(key: key, runtime: runtime)
        model.workspaceLayouts[key] = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [session.id]))
        )
        let paneController = try #require(model.currentTerminalPaneController)
        let bonsplitController = paneController.controller
        let pane = try #require(bonsplitController.allPaneIds.first)
        var tab = try #require(bonsplitController.tabs(inPane: pane).first)

        #expect(tab.title == "vim")
        #expect(model.setTerminalTabCustomTitle("  Build  ", for: session.id, in: key))
        #expect(paneController.controller === bonsplitController)
        tab = try #require(bonsplitController.tabs(inPane: pane).first)
        #expect(tab.title == "Build")
        #expect(tab.hasCustomTitle)
        #expect(model.sessionDisplayName(session, on: runtime) == "Build")

        #expect(runtime.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": session.id, "title": "ssh"]
        ))
        paneController.refreshTabMetadata()
        #expect(bonsplitController.tabs(inPane: pane).first?.title == "Build")

        paneController.splitTabBar(
            bonsplitController,
            didRequestTabContextAction: .clearName,
            for: tab,
            inPane: pane
        )
        #expect(paneController.controller === bonsplitController)
        tab = try #require(bonsplitController.tabs(inPane: pane).first)
        #expect(tab.title == "ssh")
        #expect(!tab.hasCustomTitle)
        #expect(model.workspaceLayouts[key]?.customTitlesBySessionId.isEmpty == true)
    }

    @MainActor
    @Test
    func remoteLayoutRevisionRestoresCustomTitle() throws {
        let key = ScopedResourceID(serverId: "server", resourceId: "workspace")
        let session = makeSession(id: "session", cwd: "/repo", title: nil)
        var remoteLayout = WorkspaceTerminalLayout(
            root: .pane(PaneTabGroup(sessionIds: [session.id]))
        )
        let didSetRemote = remoteLayout.setCustomTitle("Remote", for: session.id)
        #expect(didSetRemote)
        let layoutData = try JSONEncoder().encode(remoteLayout)
        let runtime = RuntimeConnection()
        runtime.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [Workspace(
                id: key.resourceId,
                name: "Workspace",
                sessionIds: [session.id],
                createdAt: "2026-07-27T00:00:00Z",
                layout: String(decoding: layoutData, as: UTF8.self),
                layoutRev: 1
            )],
            sessions: [session],
            focus: []
        )
        let model = makeModel(key: key, runtime: runtime)

        model.reconcileLayoutState()

        #expect(model.workspaceLayouts[key]?.customTitlesBySessionId == [session.id: "Remote"])
        #expect(model.terminalTabTitle(session.id, for: key) == "Remote")
    }

    @MainActor
    private func makeModel(
        key: ScopedResourceID,
        runtime: RuntimeConnection
    ) -> WorkbenchModel {
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
        return model
    }

    private func makeWorkspace(key: ScopedResourceID, sessionId: String) -> Workspace {
        Workspace(
            id: key.resourceId,
            name: "Workspace",
            sessionIds: [sessionId],
            createdAt: "2026-07-27T00:00:00Z",
            layout: nil,
            layoutRev: nil
        )
    }

    private func makeSession(id: String, cwd: String, title: String?) -> Session {
        Session(
            id: id,
            cwd: cwd,
            command: "zsh",
            cols: 80,
            rows: 24,
            createdAt: "2026-07-27T00:00:00Z",
            alive: true,
            exitCode: nil,
            title: title,
            agent: nil
        )
    }
}
