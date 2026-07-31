import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
@Suite(.serialized)
struct IdleSessionCleanupTests {
    @Test
    func dismissalStoreRoundTripsExactActivityWatermarks() throws {
        let fixture = makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let updatedAt = Date(timeIntervalSince1970: 1_234.567_89)
        let session = makeSession(
            id: "idle-session",
            phase: .completed,
            updatedAt: updatedAt
        )
        let record = IdleSessionDismissalRecord(
            session: session,
            dismissedAt: Date(timeIntervalSince1970: 2_000.125)
        )

        try fixture.store.save([session.id: record])
        let reloaded = try fixture.store.load()

        #expect(reloaded == [session.id: record])
        #expect(reloaded[session.id]?.hides(session) == true)

        var resumed = session
        resumed.updatedAt = updatedAt.addingTimeInterval(0.001)
        #expect(reloaded[session.id]?.hides(resumed) == false)
    }

    @Test
    func bulkCleanupOnlyClearsLocalIdleRecordsAndKeepsRuntimeState() throws {
        let fixture = makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let now = Date.now
        let visibleIdle = makeSession(
            id: "visible-idle",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true
        )
        let cachedIdle = makeSession(
            id: "cached-idle",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: false
        )
        let running = makeSession(
            id: "running",
            phase: .running,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true
        )
        let actionable = makeSession(
            id: "actionable",
            phase: .waitingForAnswer,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true
        )
        let recentCompletion = makeSession(
            id: "recent-completion",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-30),
            isProcessAlive: true
        )
        let remoteIdle = makeSession(
            id: "remote-idle",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true,
            isRemote: true
        )

        let model = AppModel(idleSessionDismissalStore: fixture.store)
        model.state = SessionState(
            sessions: [
                visibleIdle,
                cachedIdle,
                running,
                actionable,
                recentCompletion,
                remoteIdle,
            ]
        )

        #expect(model.clearableIdleSessionRecordCount(at: now) == 2)
        #expect(model.clearAllIdleSessionRecords(at: now) == 2)

        let rawIDs = Set(model.state.sessions.map(\.id))
        #expect(rawIDs.contains(visibleIdle.id))
        #expect(rawIDs.contains(cachedIdle.id))
        #expect(model.state.session(id: running.id)?.phase == .running)
        #expect(model.state.session(id: actionable.id)?.phase == .waitingForAnswer)

        let displayedIDs = Set(model.allSessions.map(\.id))
        #expect(!displayedIDs.contains(visibleIdle.id))
        #expect(!displayedIDs.contains(cachedIdle.id))
        #expect(displayedIDs.contains(running.id))
        #expect(displayedIDs.contains(actionable.id))
        #expect(displayedIDs.contains(recentCompletion.id))
        #expect(displayedIDs.contains(remoteIdle.id))

        let persistedIDs = Set(try fixture.store.load().keys)
        #expect(persistedIDs == [visibleIdle.id, cachedIdle.id])
    }

    @Test
    func cleanupPersistsAcrossRestartAndUnchangedRediscovery() {
        let fixture = makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let now = Date.now
        let idle = makeSession(
            id: "rediscovered-idle",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true
        )

        let firstModel = AppModel(idleSessionDismissalStore: fixture.store)
        firstModel.state = SessionState(sessions: [idle])
        #expect(firstModel.clearIdleSessionRecord(idle.id, at: now))
        #expect(firstModel.allSessions.isEmpty)

        let restartedModel = AppModel(idleSessionDismissalStore: fixture.store)
        restartedModel.state = SessionState(sessions: [idle])
        #expect(restartedModel.allSessions.isEmpty)

        var unchangedRediscovery = idle
        unchangedRediscovery.attachmentState = .attached
        unchangedRediscovery.isProcessAlive = true
        restartedModel.state = SessionState(sessions: [unchangedRediscovery])

        #expect(restartedModel.allSessions.isEmpty)
        #expect(restartedModel.clearableIdleSessionRecordCount(at: now) == 0)
    }

    @Test
    func newerSessionActivityAutomaticallyRestoresClearedRecord() throws {
        let fixture = makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let now = Date.now
        let idle = makeSession(
            id: "resumed-session",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-1_800),
            isProcessAlive: true
        )
        let model = AppModel(idleSessionDismissalStore: fixture.store)
        model.state = SessionState(sessions: [idle])

        #expect(model.clearIdleSessionRecord(idle.id, at: now))
        #expect(model.allSessions.isEmpty)

        model.applyTrackedEvent(
            .sessionStarted(
                SessionStarted(
                    sessionID: idle.id,
                    title: idle.title,
                    tool: idle.tool,
                    origin: .live,
                    summary: "A new turn started.",
                    timestamp: now
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        #expect(model.allSessions.map(\.id) == [idle.id])
        #expect(model.state.session(id: idle.id)?.phase == .running)
        #expect(try fixture.store.load().isEmpty)
    }

    @Test
    func runningAndActionableSessionsCannotBeCleared() {
        let fixture = makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let old = Date.now.addingTimeInterval(-7_200)
        let running = makeSession(
            id: "running",
            phase: .running,
            updatedAt: old,
            isProcessAlive: true
        )
        let approval = makeSession(
            id: "approval",
            phase: .waitingForApproval,
            updatedAt: old,
            isProcessAlive: true
        )
        let model = AppModel(idleSessionDismissalStore: fixture.store)
        model.state = SessionState(sessions: [running, approval])

        #expect(!model.clearIdleSessionRecord(running.id))
        #expect(!model.clearIdleSessionRecord(approval.id))
        #expect(model.clearAllIdleSessionRecords() == 0)
        #expect(model.allSessions.count == 2)
    }

    private func makeStoreFixture() -> (
        rootURL: URL,
        store: IdleSessionDismissalStore
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-idle-cleanup-\(UUID().uuidString)", isDirectory: true)
        return (
            rootURL,
            IdleSessionDismissalStore(
                fileURL: rootURL.appendingPathComponent("dismissed-idle-sessions.json")
            )
        )
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        updatedAt: Date,
        isProcessAlive: Bool = true,
        isRemote: Bool = false
    ) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Codex · \(id)",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: phase.displayName,
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "test",
                paneTitle: id,
                workingDirectory: "/tmp/test",
                codexThreadID: id
            )
        )
        session.isCodexAppSession = true
        session.isProcessAlive = isProcessAlive
        session.isRemote = isRemote
        return session
    }
}
