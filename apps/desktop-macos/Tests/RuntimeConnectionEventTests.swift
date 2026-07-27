import Foundation
import Testing
@testable import AcroDesktop

@MainActor
struct RuntimeConnectionEventTests {
    @Test
    func sessionTitleEventUpdatesOnlyTheTargetSession() {
        let connection = RuntimeConnection()
        connection.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [
                Session(
                    id: "session", cwd: "/tmp", command: "zsh", cols: 80, rows: 24,
                    createdAt: "2026-07-19T00:00:00Z", alive: true, exitCode: nil,
                    title: nil,
                    agent: AgentSession(
                        provider: "codex", state: "working", providerSessionId: "provider",
                        codexHome: nil,
                        accountFingerprint: nil,
                        managed: true, interrupted: false,
                        updatedAt: "2026-07-19T00:00:00Z"
                    )
                )
            ],
            focus: []
        )

        #expect(connection.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": "session", "title": "vim"]
        ))
        #expect(connection.sessions.first?.title == "vim")
        #expect(connection.sessions.first?.agent?.providerSessionId == "provider")
        #expect(connection.snapshotRevision == 1)
        #expect(!connection.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": "missing", "title": "ignored"]
        ))
    }

    @Test
    func focusEventUpdatesOwnerWithoutRefreshingTheSnapshot() {
        let connection = RuntimeConnection()
        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: [])
        let revision = connection.snapshotRevision

        #expect(connection.applyIncrementalEvent(
            "session.focusChanged",
            payload: [
                "sessionId": "session",
                "deviceId": "device",
                "deviceName": "MacBook",
            ]
        ))
        #expect(connection.focusOwners["session"]?.deviceName == "MacBook")
        #expect(connection.snapshotRevision == revision)

        #expect(connection.applyIncrementalEvent(
            "session.focusChanged",
            payload: [
                "sessionId": "session",
                "deviceId": NSNull(),
                "deviceName": NSNull(),
            ]
        ))
        #expect(connection.focusOwners["session"] == nil)
        #expect(connection.snapshotRevision == revision)
    }

    @Test
    func unusedControlEventsDoNotRefreshTerminalState() {
        let connection = RuntimeConnection()
        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: [])
        let revision = connection.snapshotRevision

        #expect(connection.applyIncrementalEvent(
            "browser.controlChanged",
            payload: ["browserId": "browser", "deviceId": NSNull(), "deviceName": NSNull()]
        ))
        #expect(connection.snapshotRevision == revision)
    }

    @Test
    func agentChangedEventUpdatesTheTargetAndSurvivesAStaleSnapshot() throws {
        let connection = RuntimeConnection()
        let working = AgentSession(
            provider: "codex",
            state: "working",
            providerSessionId: "provider",
            codexHome: nil,
            accountFingerprint: nil,
            managed: true,
            interrupted: false,
            updatedAt: "2026-07-19T00:00:00Z"
        )
        let session = Session(
            id: "session", cwd: "/tmp", command: "zsh", cols: 80, rows: 24,
            createdAt: "2026-07-19T00:00:00Z", alive: true, exitCode: nil,
            title: nil, agent: working
        )
        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [session], focus: [])
        let revision = connection.snapshotRevision

        #expect(connection.applyIncrementalEvent(
            "session.agentChanged",
            payload: [
                "sessionId": "session",
                "agent": [
                    "provider": "codex",
                    "state": "waiting",
                    "providerSessionId": "provider",
                    "codexHome": NSNull(),
                    "accountFingerprint": NSNull(),
                    "managed": true,
                    "interrupted": false,
                    "updatedAt": "2026-07-19T00:01:00Z",
                ],
            ]
        ))
        #expect(connection.sessions.first?.agent?.state == "waiting")
        #expect(connection.snapshotRevision == revision + 1)

        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [session], focus: [])
        #expect(connection.sessions.first?.agent?.state == "waiting")

        #expect(!connection.applyIncrementalEvent(
            "session.agentChanged",
            payload: ["sessionId": "session"]
        ))
    }

    @Test
    func identicalSnapshotDoesNotPublishANewRevision() {
        let connection = RuntimeConnection()
        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: [])
        let revision = connection.snapshotRevision

        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [], focus: [])

        #expect(connection.snapshotRevision == revision)
    }
}
