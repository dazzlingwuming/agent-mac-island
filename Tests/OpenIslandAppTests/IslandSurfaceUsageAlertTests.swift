import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct IslandSurfaceUsageAlertTests {
    @Test
    func usageAlertIsAnIndependentTimedNotificationSurface() {
        let surface = IslandSurface.codexUsageAlert(alert())

        #expect(surface.isNotificationSurface)
        #expect(surface.isNotificationCard)
        #expect(surface.sessionID == nil)
        #expect(surface.autoDismissesWhenPresentedAsNotification(session: nil))
    }

    @Test
    func usageAlertSurvivesSessionStateReconciliation() {
        let surface = IslandSurface.codexUsageAlert(alert())
        let runningSession = AgentSession(
            id: "unrelated-session",
            title: "Codex · unrelated",
            tool: .codex,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )

        #expect(surface.matchesCurrentState(of: nil))
        #expect(surface.matchesCurrentState(of: runningSession))
    }

    @Test
    func sessionCompletionAndActionableNotificationsKeepTheirExistingLifecycle() {
        let completed = AgentSession(
            id: "completed",
            title: "Codex · completed",
            tool: .codex,
            attachmentState: .attached,
            phase: .completed,
            summary: "Done",
            updatedAt: .now
        )
        let approval = AgentSession(
            id: "approval",
            title: "Codex · approval",
            tool: .codex,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Allow command",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Allow command",
                summary: "Needs approval",
                affectedPath: "/tmp/project"
            )
        )

        let completedSurface = IslandSurface.sessionList(actionableSessionID: completed.id)
        let approvalSurface = IslandSurface.sessionList(actionableSessionID: approval.id)

        #expect(completedSurface.matchesCurrentState(of: completed))
        #expect(completedSurface.autoDismissesWhenPresentedAsNotification(session: completed))
        #expect(approvalSurface.matchesCurrentState(of: approval))
        #expect(!approvalSurface.autoDismissesWhenPresentedAsNotification(session: approval))
    }

    @Test
    @MainActor
    func usageAlertUsesTheExistingTimedNotificationAndHoverPauseLifecycle() {
        let model = AppModel()
        model.isSoundMuted = true
        let surface = IslandSurface.codexUsageAlert(alert())

        #expect(model.overlay.presentNotificationSurface(surface))
        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
        #expect(model.islandSurface == surface)
        #expect(model.hasPendingNotificationAutoCollapse)

        model.notePointerInsideIslandSurface()

        #expect(!model.hasPendingNotificationAutoCollapse)
        #expect(model.shouldDeferTimedNotificationAutoCollapse)
        #expect(model.notchStatus == .opened)
    }

    @Test
    @MainActor
    func usageAlertCannotReplaceAnActionableSessionNotification() {
        let model = AppModel()
        model.isSoundMuted = true
        let approval = AgentSession(
            id: "approval",
            title: "Codex · approval",
            tool: .codex,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Allow command",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Allow command",
                summary: "Needs approval",
                affectedPath: "/tmp/project"
            )
        )
        let approvalSurface = IslandSurface.sessionList(actionableSessionID: approval.id)
        model.state = SessionState(sessions: [approval])
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = approvalSurface

        #expect(!model.overlay.presentNotificationSurface(.codexUsageAlert(alert())))
        #expect(model.islandSurface == approvalSurface)
        #expect(model.notchStatus == .opened)
    }

    @Test
    @MainActor
    func actionableSessionNotificationReplacesEvenAHoveredUsageAlert() {
        let model = AppModel()
        model.isSoundMuted = true
        let usageSurface = IslandSurface.codexUsageAlert(alert())
        #expect(model.overlay.presentNotificationSurface(usageSurface))
        model.notePointerInsideIslandSurface()

        let approval = AgentSession(
            id: "urgent-approval",
            title: "Codex · approval",
            tool: .codex,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Allow command",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Allow command",
                summary: "Needs approval",
                affectedPath: "/tmp/project"
            )
        )
        let approvalSurface = IslandSurface.sessionList(actionableSessionID: approval.id)
        model.state = SessionState(sessions: [approval])

        #expect(model.overlay.presentNotificationSurface(approvalSurface))
        #expect(model.islandSurface == approvalSurface)
        #expect(!model.hasPendingNotificationAutoCollapse)
    }

    private func alert() -> CodexUsagePaceAlert {
        CodexUsagePaceAlert(
            id: "long|10080|1|fast",
            notificationKey: "long|10080|1",
            risk: .fast,
            severity: .fast,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            usedPercentage: 40,
            shortTermUsedPercentage: 15,
            todayIncreasePercentage: 12,
            recentDailyRatePercentage: 20,
            recommendedDailyPercentage: 8,
            projectedExhaustionAt: Date(timeIntervalSince1970: 1_800_100_000),
            resetsAt: Date(timeIntervalSince1970: 1_800_432_000),
            hasSufficientTrendData: true
        )
    }
}
