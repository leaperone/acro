import AppKit
import Testing
@testable import AcroDesktop

@Suite(.serialized)
struct AppLifecycleTests {
    @Test
    func commandQRemainsOwnedByTheApp() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 12
        ))

        #expect(ShortcutSettings.isAppShortcut(event))
        #expect(ShortcutSettings.action(for: event) == nil)
        #expect(
            ShortcutSettings.reservedShortcutDescription(StoredShortcut.from(event))
                == "⌘Q 固定用于退出 Acro"
        )
    }

    @MainActor
    @Test
    func startupSelectsTheWorkspaceContainingTheLiveTerminal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acro-startup-workspace-\(UUID().uuidString)")
        let configPath = root.appendingPathComponent("client.json")
        setenv("ACRO_CLIENT_CONFIG", configPath.path, 1)
        let server = ServerEntry(
            localId: "server", name: "本机", deviceId: "device", token: "token",
            pub: Data(repeating: 1, count: 32).base64EncodedString(),
            endpoints: ["127.0.0.1:1"]
        )
        ClientConfig(v: 2, servers: [server], active: server.id).save()
        let hub = RuntimeHub()
        hub.reload()
        defer {
            hub.entries.forEach { $0.connection.disconnect() }
            unsetenv("ACRO_CLIENT_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }

        let connection = try #require(hub.connection(for: server.id))
        let empty = workspace(id: "empty", sessionIds: [])
        let live = workspace(id: "live", sessionIds: ["session"])
        connection.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [empty, live],
            sessions: [session(id: "session")],
            focus: []
        )
        let model = WorkbenchModel(hub: hub)
        model.selectedWorkspaceId = empty.id
        model.reconcileLayoutState()

        model.selectLiveWorkspaceOnStartupIfNeeded()

        #expect(model.selectedWorkspaceId == live.id)
        #expect(model.selectedSessionId == "session")

        model.selectedWorkspaceId = empty.id
        model.resetStartupWorkspaceSelection()
        model.selectLiveWorkspaceOnStartupIfNeeded()

        #expect(model.selectedWorkspaceId == live.id)
    }

    private func workspace(id: String, sessionIds: [String]) -> Workspace {
        Workspace(
            id: id,
            name: id,
            sessionIds: sessionIds,
            createdAt: "2026-07-19T00:00:00.000Z",
            layout: nil,
            layoutRev: 0
        )
    }

    private func session(id: String) -> Session {
        Session(
            id: id,
            cwd: "/tmp",
            command: "/bin/zsh",
            cols: 80,
            rows: 24,
            createdAt: "2026-07-19T00:00:00.000Z",
            alive: true,
            exitCode: nil,
            title: nil,
            agent: nil
        )
    }
}
