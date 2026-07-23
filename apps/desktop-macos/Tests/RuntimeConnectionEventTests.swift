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
}
