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
                    title: nil
                )
            ],
            focus: []
        )

        #expect(connection.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": "session", "title": "vim"]
        ))
        #expect(connection.sessions.first?.title == "vim")
        #expect(connection.snapshotRevision == 1)
        #expect(!connection.applyIncrementalEvent(
            "session.title",
            payload: ["sessionId": "missing", "title": "ignored"]
        ))
    }
}
