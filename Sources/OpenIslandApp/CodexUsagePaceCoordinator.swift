import Foundation
import OpenIslandCore

struct CodexUsagePaceNotificationRecord: Codable, Equatable, Sendable {
    let risk: CodexUsagePaceRisk
    let notifiedAt: Date
}

struct CodexUsagePacePersistedState: Codable, Equatable, Sendable {
    var samples: [CodexUsagePaceSample] = []
    var notifications: [String: CodexUsagePaceNotificationRecord] = [:]
    var planType: String?
    var limitID: String?
}

final class CodexUsagePaceStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let state: CodexUsagePacePersistedState
    }

    static let currentVersion = 1

    static var defaultFileURL: URL {
        CodexSessionStore.defaultDirectoryURL
            .appendingPathComponent("codex-usage-pace.json")
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = CodexUsagePaceStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> CodexUsagePacePersistedState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CodexUsagePacePersistedState()
        }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == Self.currentVersion else {
            return CodexUsagePacePersistedState()
        }
        return document.state
    }

    func save(_ state: CodexUsagePacePersistedState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            Document(version: Self.currentVersion, state: state)
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class CodexUsagePaceCoordinator {
    private static let historyRetention: TimeInterval = 14 * 24 * 60 * 60
    private static let maximumSampleCount = 1_024
    private static let maximumNotificationCount = 24

    private let store: CodexUsagePaceStore
    private var persistedState: CodexUsagePacePersistedState

    init(store: CodexUsagePaceStore = CodexUsagePaceStore()) {
        self.store = store
        persistedState = (try? store.load()) ?? CodexUsagePacePersistedState()
    }

    /// Records the latest numeric quota sample and returns a notification
    /// candidate. The candidate is not marked delivered until
    /// `recordPresentation(of:)` is called, so an actionable session card can
    /// safely defer the warning without losing it.
    func ingest(
        _ snapshot: CodexUsageSnapshot,
        alertsEnabled: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CodexUsagePaceAlert? {
        // Pace alerts intentionally follow the ordinary aggregate Codex pool.
        // Model-specific pools such as codex_bengalfox must not replace its
        // persisted history or create a misleading 0% alert baseline.
        guard snapshot.limitID == "codex" else {
            return nil
        }

        resetForChangedLimitIfNeeded(snapshot)

        let evaluation = CodexUsagePaceEvaluator.evaluate(
            snapshot: snapshot,
            samples: persistedState.samples,
            now: now,
            calendar: calendar
        )

        if evaluation.status == .fresh {
            appendFreshSamples(from: snapshot)
            pruneState(relativeTo: now)
            persistBestEffort()
        }

        guard alertsEnabled,
              evaluation.status == .fresh,
              evaluation.risk > .normal,
              let alert = makeAlert(from: evaluation),
              shouldPresent(alert) else {
            return nil
        }

        return alert
    }

    func recordPresentation(of alert: CodexUsagePaceAlert) {
        persistedState.notifications[alert.notificationKey] =
            CodexUsagePaceNotificationRecord(
                risk: alert.risk,
                notifiedAt: alert.observedAt
            )
        pruneNotificationRecords()
        persistBestEffort()
    }

    private func resetForChangedLimitIfNeeded(_ snapshot: CodexUsageSnapshot) {
        let changedPlan = persistedState.planType != nil
            && snapshot.planType != nil
            && persistedState.planType != snapshot.planType
        let changedLimit = persistedState.limitID != nil
            && snapshot.limitID != nil
            && persistedState.limitID != snapshot.limitID

        if changedPlan || changedLimit {
            persistedState = CodexUsagePacePersistedState()
        }
        persistedState.planType = snapshot.planType ?? persistedState.planType
        persistedState.limitID = snapshot.limitID ?? persistedState.limitID
    }

    private func appendFreshSamples(from snapshot: CodexUsageSnapshot) {
        guard let capturedAt = snapshot.capturedAt else { return }

        for window in snapshot.windows where window.windowMinutes > 0 {
            let sample = CodexUsagePaceSample(
                capturedAt: capturedAt,
                usedPercentage: window.usedPercentage,
                windowMinutes: window.windowMinutes,
                resetsAt: window.resetsAt
            )
            if let index = persistedState.samples.firstIndex(where: {
                $0.capturedAt == sample.capturedAt
                    && $0.windowMinutes == sample.windowMinutes
                    && $0.resetsAt == sample.resetsAt
            }) {
                persistedState.samples[index] = sample
            } else {
                persistedState.samples.append(sample)
            }
        }
    }

    private func pruneState(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        persistedState.samples = persistedState.samples
            .filter { $0.capturedAt >= cutoff && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        if persistedState.samples.count > Self.maximumSampleCount {
            persistedState.samples.removeFirst(
                persistedState.samples.count - Self.maximumSampleCount
            )
        }
        pruneNotificationRecords()
    }

    private func pruneNotificationRecords() {
        guard persistedState.notifications.count > Self.maximumNotificationCount else {
            return
        }
        let retainedKeys = persistedState.notifications
            .sorted { $0.value.notifiedAt > $1.value.notifiedAt }
            .prefix(Self.maximumNotificationCount)
            .map(\.key)
        let retained = Set(retainedKeys)
        persistedState.notifications = persistedState.notifications.filter {
            retained.contains($0.key)
        }
    }

    private func makeAlert(
        from evaluation: CodexUsagePaceEvaluation
    ) -> CodexUsagePaceAlert? {
        guard let observedAt = evaluation.capturedAt else { return nil }

        let dominant = dominantAssessment(in: evaluation)
        let longTerm = evaluation.longTerm
        let displayAssessment = longTerm ?? dominant
        guard let displayAssessment else { return nil }

        let notificationKey = periodKey(
            for: dominant ?? displayAssessment,
            risk: evaluation.risk,
            observedAt: observedAt
        )
        let exhaustionAt = longTerm?.estimatedHoursUntilExhaustion.map {
            observedAt.addingTimeInterval($0 * 60 * 60)
        }

        return CodexUsagePaceAlert(
            id: "\(notificationKey)|\(evaluation.risk.rawValue)",
            notificationKey: notificationKey,
            risk: evaluation.risk,
            severity: alertSeverity(for: evaluation.risk),
            observedAt: observedAt,
            usedPercentage: displayAssessment.window.usedPercentage,
            shortTermUsedPercentage: evaluation.shortTerm?.window.usedPercentage,
            todayIncreasePercentage: longTerm?.todayUsedPercentage,
            recentDailyRatePercentage: longTerm?.recentBurnRatePerDay,
            recommendedDailyPercentage: longTerm?.remainingDailyBudget,
            projectedExhaustionAt: exhaustionAt,
            resetsAt: longTerm?.window.resetsAt ?? displayAssessment.window.resetsAt,
            hasSufficientTrendData: longTerm?.recentBurnRatePerDay != nil
        )
    }

    private func dominantAssessment(
        in evaluation: CodexUsagePaceEvaluation
    ) -> CodexUsagePaceWindowAssessment? {
        let candidates = [evaluation.longTerm, evaluation.shortTerm].compactMap { $0 }
        return candidates.max { lhs, rhs in lhs.risk < rhs.risk }
    }

    private func periodKey(
        for assessment: CodexUsagePaceWindowAssessment,
        risk: CodexUsagePaceRisk,
        observedAt: Date
    ) -> String {
        let resetComponent = assessment.window.resetsAt?
            .timeIntervalSince1970
            .rounded()
            .description ?? "unknown-\(Int(observedAt.timeIntervalSince1970 / 86_400))"
        let scope = assessment.window.windowMinutes < 24 * 60 ? "short" : "long"
        _ = risk
        return "\(scope)|\(assessment.window.windowMinutes)|\(resetComponent)"
    }

    private func shouldPresent(_ alert: CodexUsagePaceAlert) -> Bool {
        guard let previous = persistedState.notifications[alert.notificationKey] else {
            return true
        }
        return previous.risk < alert.risk
    }

    private func alertSeverity(
        for risk: CodexUsagePaceRisk
    ) -> CodexUsageAlertSeverity {
        switch risk {
        case .normal, .attention:
            .attention
        case .fast:
            .fast
        case .critical:
            .critical
        }
    }

    private func persistBestEffort() {
        try? store.save(persistedState)
    }
}
