import Foundation
import OpenIslandCore

enum CodexUsageAlertSeverity: String, Equatable, Sendable {
    case attention
    case fast
    case critical
}

struct CodexUsagePaceAlert: Equatable, Sendable, Identifiable {
    let id: String
    let notificationKey: String
    let risk: CodexUsagePaceRisk
    let severity: CodexUsageAlertSeverity
    let observedAt: Date
    let usedPercentage: Double
    let previousUsedPercentage: Double?
    let shortTermUsedPercentage: Double?
    let todayIncreasePercentage: Double?
    let recentDailyRatePercentage: Double?
    let recommendedDailyPercentage: Double?
    let projectedExhaustionAt: Date?
    let resetsAt: Date?
    let hasSufficientTrendData: Bool
}

enum IslandSurface: Equatable {
    case sessionList(actionableSessionID: String? = nil)
    case codexUsageAlert(CodexUsagePaceAlert)

    var sessionID: String? {
        switch self {
        case let .sessionList(actionableSessionID):
            actionableSessionID
        case .codexUsageAlert:
            nil
        }
    }

    var codexUsageAlert: CodexUsagePaceAlert? {
        guard case let .codexUsageAlert(alert) = self else {
            return nil
        }
        return alert
    }

    var isNotificationSurface: Bool {
        switch self {
        case let .sessionList(actionableSessionID):
            actionableSessionID != nil
        case .codexUsageAlert:
            true
        }
    }

    /// Compatibility spelling retained for the session-oriented callers.
    var isNotificationCard: Bool {
        isNotificationSurface
    }

    func autoDismissesWhenPresentedAsNotification(session: AgentSession?) -> Bool {
        switch self {
        case let .sessionList(actionableSessionID):
            guard actionableSessionID != nil else { return false }
            return session?.phase == .completed
        case .codexUsageAlert:
            return true
        }
    }

    static func notificationSurface(for event: AgentEvent) -> IslandSurface? {
        switch event {
        case let .permissionRequested(payload):
            .sessionList(actionableSessionID: payload.sessionID)
        case let .questionAsked(payload):
            .sessionList(actionableSessionID: payload.sessionID)
        case let .sessionCompleted(payload):
            payload.isInterrupt == true ? nil : .sessionList(actionableSessionID: payload.sessionID)
        default:
            nil
        }
    }

    func matchesCurrentState(of session: AgentSession?) -> Bool {
        if case .codexUsageAlert = self { return true }
        guard sessionID != nil else { return true }

        guard let session else {
            return false
        }

        switch session.phase {
        case .waitingForApproval:
            return session.permissionRequest != nil
        case .waitingForAnswer:
            return session.questionPrompt != nil
        case .completed:
            return true
        case .running:
            return false
        }
    }
}
