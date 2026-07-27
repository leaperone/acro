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
    func agentChangedEventPreservesAttentionAfterTheAgentKeepsWorking() throws {
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
        #expect(connection.agentAttentionSignals["session"]?.state == "waiting")
        #expect(connection.snapshotRevision == revision + 1)

        #expect(connection.applyIncrementalEvent(
            "session.agentChanged",
            payload: [
                "sessionId": "session",
                "agent": [
                    "provider": "codex",
                    "state": "working",
                    "providerSessionId": "provider",
                    "codexHome": NSNull(),
                    "accountFingerprint": NSNull(),
                    "managed": true,
                    "interrupted": false,
                    "updatedAt": "2026-07-19T00:02:00Z",
                ],
            ]
        ))
        #expect(connection.sessions.first?.agent?.state == "working")
        #expect(connection.agentAttentionSignals["session"]?.state == "waiting")

        let detached = Session(
            id: session.id,
            cwd: session.cwd,
            command: session.command,
            cols: session.cols,
            rows: session.rows,
            createdAt: session.createdAt,
            alive: session.alive,
            exitCode: session.exitCode,
            title: session.title,
            agent: nil
        )
        connection.commitRefreshSnapshot(
            workspaceGroups: [],
            workspaces: [],
            sessions: [detached],
            focus: [],
            snapshotAgentEventVersion: 0
        )
        #expect(connection.agentAttentionSignals["session"]?.state == "waiting")
        #expect(connection.sessions.first?.agent?.state == "working")

        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [detached], focus: [])
        #expect(connection.agentAttentionSignals["session"] == nil)

        #expect(!connection.applyIncrementalEvent(
            "session.agentChanged",
            payload: ["sessionId": "session"]
        ))
    }

    @Test
    func queuedRefreshCapturesAgentVersionWhenItStarts() async throws {
        let workingA = AgentSession(
            provider: "codex",
            state: "working",
            providerSessionId: "provider-a",
            codexHome: nil,
            accountFingerprint: nil,
            managed: true,
            interrupted: false,
            updatedAt: "2026-07-19T00:00:00Z"
        )
        let waitingB = AgentSession(
            provider: "codex",
            state: "waiting",
            providerSessionId: "provider-b",
            codexHome: nil,
            accountFingerprint: nil,
            managed: true,
            interrupted: false,
            updatedAt: "2026-07-19T00:00:00Z"
        )
        let sessionA = Session(
            id: "session-a", cwd: "/tmp", command: "zsh", cols: 80, rows: 24,
            createdAt: "2026-07-19T00:00:00Z", alive: true, exitCode: nil,
            title: nil, agent: workingA
        )
        let sessionB = Session(
            id: "session-b", cwd: "/tmp", command: "zsh", cols: 80, rows: 24,
            createdAt: "2026-07-19T00:00:00Z", alive: true, exitCode: nil,
            title: nil, agent: waitingB
        )
        let detachedA = Session(
            id: sessionA.id, cwd: sessionA.cwd, command: sessionA.command,
            cols: sessionA.cols, rows: sessionA.rows, createdAt: sessionA.createdAt,
            alive: sessionA.alive, exitCode: sessionA.exitCode, title: sessionA.title, agent: nil
        )
        let detachedB = Session(
            id: sessionB.id, cwd: sessionB.cwd, command: sessionB.command,
            cols: sessionB.cols, rows: sessionB.rows, createdAt: sessionB.createdAt,
            alive: sessionB.alive, exitCode: sessionB.exitCode, title: sessionB.title, agent: nil
        )
        var loadCount = 0
        var firstRelease: CheckedContinuation<Void, Never>?
        var secondRelease: CheckedContinuation<Void, Never>?
        let connection = RuntimeConnection(refreshSnapshotProvider: {
            loadCount += 1
            if loadCount == 1 {
                await withCheckedContinuation { firstRelease = $0 }
            } else if loadCount == 2 {
                await withCheckedContinuation { secondRelease = $0 }
            }
            return .init(
                workspaceGroups: [], workspaces: [], sessions: [detachedA, detachedB], focus: []
            )
        })
        connection.commitRefreshSnapshot(
            workspaceGroups: [], workspaces: [], sessions: [sessionA, sessionB], focus: [])
        #expect(connection.agentAttentionSignals[sessionB.id]?.state == "waiting")

        let firstRefresh = Task { await connection.refresh() }
        for _ in 0..<1_000 where firstRelease == nil { await Task.yield() }
        let releaseFirst = try #require(firstRelease)
        var trailingStarted = false
        let trailingRefresh = Task {
            trailingStarted = true
            return await connection.refresh()
        }
        for _ in 0..<1_000 where !trailingStarted { await Task.yield() }
        #expect(trailingStarted)

        #expect(connection.applyIncrementalEvent(
            "session.agentChanged",
            payload: [
                "sessionId": sessionA.id,
                "agent": [
                    "provider": "codex",
                    "state": "waiting",
                    "providerSessionId": "provider-a",
                    "codexHome": NSNull(),
                    "accountFingerprint": NSNull(),
                    "managed": true,
                    "interrupted": false,
                    "updatedAt": "2026-07-19T00:01:00Z",
                ],
            ]
        ))
        releaseFirst.resume()
        for _ in 0..<1_000 where secondRelease == nil { await Task.yield() }
        let releaseSecond = try #require(secondRelease)

        #expect(await firstRefresh.value)
        #expect(connection.agentAttentionSignals[sessionA.id]?.state == "waiting")
        #expect(connection.agentAttentionSignals[sessionB.id] == nil)
        #expect(connection.sessions.first(where: { $0.id == sessionA.id })?.agent?.state == "waiting")
        #expect(connection.sessions.first(where: { $0.id == sessionB.id })?.agent == nil)

        releaseSecond.resume()
        #expect(await trailingRefresh.value)
        #expect(connection.agentAttentionSignals[sessionA.id] == nil)
        #expect(connection.agentAttentionSignals[sessionB.id] == nil)
        #expect(connection.sessions.allSatisfy { $0.agent == nil })
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
