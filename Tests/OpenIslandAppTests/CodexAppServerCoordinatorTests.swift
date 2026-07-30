import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct CodexAppServerCoordinatorTests {
    @Test
    func completedTurnEmitsNotificationWorthyCompletionWithoutEndingThread() throws {
        let coordinator = CodexAppServerCoordinator()
        var received: AgentEvent?
        coordinator.onEvent = { received = $0 }

        let turn = try decodeTurn(status: "completed")
        coordinator.handleNotification(.turnCompleted(threadId: "thread-1", turn: turn))

        guard let received,
              case let .sessionCompleted(payload) = received else {
            Issue.record("Expected a sessionCompleted event")
            return
        }
        #expect(payload.sessionID == "thread-1")
        #expect(payload.summary == "Turn completed.")
        #expect(payload.isSessionEnd != true)
        #expect(payload.isInterrupt != true)
    }

    @Test
    func idleStatusAlsoEmitsTurnLevelCompletion() throws {
        let coordinator = CodexAppServerCoordinator()
        var received: AgentEvent?
        coordinator.onEvent = { received = $0 }

        coordinator.handleNotification(
            .threadStatusChanged(
                threadId: "thread-idle",
                status: try decodeStatus(type: "idle")
            )
        )

        guard let received,
              case let .sessionCompleted(payload) = received else {
            Issue.record("Expected a sessionCompleted event")
            return
        }
        #expect(payload.sessionID == "thread-idle")
        #expect(payload.summary == "Turn completed.")
        #expect(payload.isSessionEnd != true)
    }

    @Test
    func failedTurnAndSystemErrorEmitCompletionEvents() throws {
        let coordinator = CodexAppServerCoordinator()
        var received: [AgentEvent] = []
        coordinator.onEvent = { received.append($0) }

        coordinator.handleNotification(
            .turnCompleted(threadId: "thread-failed", turn: try decodeTurn(status: "failed"))
        )
        coordinator.handleNotification(
            .threadStatusChanged(
                threadId: "thread-system-error",
                status: try decodeStatus(type: "systemError")
            )
        )

        let completions = received.compactMap { event -> SessionCompleted? in
            guard case let .sessionCompleted(payload) = event else { return nil }
            return payload
        }
        #expect(completions.map(\.sessionID) == ["thread-failed", "thread-system-error"])
        #expect(completions.allSatisfy { $0.summary == "Turn failed." })
        #expect(completions.allSatisfy { $0.isSessionEnd != true })
    }

    @Test
    func interruptedTurnRemainsSuppressedByCompletionNotificationPolicy() throws {
        let coordinator = CodexAppServerCoordinator()
        var received: AgentEvent?
        coordinator.onEvent = { received = $0 }

        coordinator.handleNotification(
            .turnCompleted(threadId: "thread-interrupted", turn: try decodeTurn(status: "interrupted"))
        )

        guard let received,
              case let .sessionCompleted(payload) = received else {
            Issue.record("Expected a sessionCompleted event")
            return
        }
        #expect(payload.isInterrupt == true)
        #expect(IslandSurface.notificationSurface(for: received) == nil)
    }

    private func decodeTurn(status: String) throws -> CodexTurn {
        try JSONDecoder().decode(
            CodexTurn.self,
            from: Data(#"{"id":"turn-1","status":"\#(status)"}"#.utf8)
        )
    }

    private func decodeStatus(type: String) throws -> CodexThreadStatus {
        try JSONDecoder().decode(
            CodexThreadStatus.self,
            from: Data(#"{"type":"\#(type)","activeFlags":null}"#.utf8)
        )
    }
}
