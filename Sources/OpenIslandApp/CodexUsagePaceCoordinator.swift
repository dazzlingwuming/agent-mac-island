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

    /// Version 2 changes the notification keys from one key per quota period
    /// to one key per observed integer percentage in that period. Version 1
    /// documents remain readable so numeric history is never discarded on
    /// upgrade.
    static let currentVersion = 2

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
        guard document.version == 1 || document.version == Self.currentVersion else {
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
    // Keep a complete 0...100 quota period. A smaller retention limit would
    // forget early percentages and allow them to be presented again.
    private static let maximumNotificationCount = 128
    private static let ordinaryCodexSevenDayWindowMinutes = 7 * 24 * 60
    /// Codex may report a reset timestamp with a one-second wobble between
    /// reads. Keep a prior nearby timestamp as the identity of that period.
    private static let resetTimestampStabilityTolerance: TimeInterval = 60

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
        let snapshot = stabilizedResetTimes(in: snapshot)

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
              let longTerm = evaluation.longTerm,
              longTerm.window.windowMinutes == Self.ordinaryCodexSevenDayWindowMinutes,
              longTerm.window.roundedUsedPercentage > 0,
              shouldConsiderPercentageCandidate(
                  for: longTerm,
                  observedAt: evaluation.capturedAt
              ),
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

    private func stabilizedResetTimes(
        in snapshot: CodexUsageSnapshot
    ) -> CodexUsageSnapshot {
        var stabilized = snapshot
        stabilized.windows = snapshot.windows.map { window in
            guard let reportedReset = window.resetsAt,
                  let storedReset = persistedState.samples
                    .filter({ $0.windowMinutes == window.windowMinutes })
                    .compactMap(\.resetsAt)
                    .min(by: {
                        abs($0.timeIntervalSince(reportedReset))
                            < abs($1.timeIntervalSince(reportedReset))
                    }),
                  abs(storedReset.timeIntervalSince(reportedReset))
                    <= Self.resetTimestampStabilityTolerance else {
                return window
            }

            var stableWindow = window
            stableWindow.resetsAt = storedReset
            return stableWindow
        }
        return stabilized
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

        let longTerm = evaluation.longTerm
        guard let longTerm,
              longTerm.window.windowMinutes == Self.ordinaryCodexSevenDayWindowMinutes else {
            return nil
        }

        let usedPercentage = longTerm.window.roundedUsedPercentage
        let previousUsedPercentage = previousDifferentObservedPercentage(
            for: longTerm,
            observedAt: observedAt
        )
        let notificationKey = percentageKey(
            periodKey: periodKey(
                for: longTerm,
                observedAt: observedAt
            ),
            usedPercentage: usedPercentage
        )
        let exhaustionAt = longTerm.estimatedHoursUntilExhaustion.map {
            observedAt.addingTimeInterval($0 * 60 * 60)
        }

        return CodexUsagePaceAlert(
            id: "\(notificationKey)|\(longTerm.risk.rawValue)",
            notificationKey: notificationKey,
            risk: longTerm.risk,
            severity: alertSeverity(for: longTerm.risk),
            observedAt: observedAt,
            usedPercentage: longTerm.window.usedPercentage,
            previousUsedPercentage: previousUsedPercentage.map(Double.init),
            shortTermUsedPercentage: evaluation.shortTerm?.window.usedPercentage,
            todayIncreasePercentage: longTerm.todayUsedPercentage,
            recentDailyRatePercentage: longTerm.recentBurnRatePerDay,
            recommendedDailyPercentage: longTerm.remainingDailyBudget,
            projectedExhaustionAt: exhaustionAt,
            resetsAt: longTerm.window.resetsAt,
            hasSufficientTrendData: longTerm.recentBurnRatePerDay != nil
        )
    }

    /// The first positive reading in a quota period is worth surfacing. After
    /// that, only a higher integer percentage introduces a new notification.
    /// Equal readings remain candidates until a presentation is recorded,
    /// allowing a suppressed or replaced card to retry safely.
    private func shouldConsiderPercentageCandidate(
        for assessment: CodexUsagePaceWindowAssessment,
        observedAt: Date?
    ) -> Bool {
        guard let observedAt,
              let previous = latestObservedPercentage(
                  for: assessment,
                  before: observedAt
              ) else {
            return true
        }
        return assessment.window.roundedUsedPercentage >= previous
    }

    private func previousDifferentObservedPercentage(
        for assessment: CodexUsagePaceWindowAssessment,
        observedAt: Date
    ) -> Int? {
        let current = assessment.window.roundedUsedPercentage
        return priorSamples(for: assessment, before: observedAt)
            .reversed()
            .map { Int($0.usedPercentage.rounded()) }
            .first(where: { $0 != current })
    }

    private func latestObservedPercentage(
        for assessment: CodexUsagePaceWindowAssessment,
        before observedAt: Date
    ) -> Int? {
        priorSamples(for: assessment, before: observedAt)
            .last
            .map { Int($0.usedPercentage.rounded()) }
    }

    private func priorSamples(
        for assessment: CodexUsagePaceWindowAssessment,
        before observedAt: Date
    ) -> [CodexUsagePaceSample] {
        persistedState.samples
            .filter { sample in
                guard sample.windowMinutes == assessment.window.windowMinutes,
                      sample.capturedAt < observedAt else {
                    return false
                }
                return isSameResetPeriod(
                    sample.resetsAt,
                    assessment.window.resetsAt
                )
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func isSameResetPeriod(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            abs(lhs.timeIntervalSince(rhs))
                <= Self.resetTimestampStabilityTolerance
        case (.none, .none):
            true
        default:
            false
        }
    }

    private func percentageKey(periodKey: String, usedPercentage: Int) -> String {
        "\(periodKey)|used-\(usedPercentage)"
    }

    private func periodKey(
        for assessment: CodexUsagePaceWindowAssessment,
        observedAt: Date
    ) -> String {
        let resetComponent = assessment.window.resetsAt.map {
            // The persisted sample anchor handles near-boundary reports within
            // a run and across restarts; minute rounding gives the first
            // report a stable, human-scale period identity as well.
            Int(($0.timeIntervalSince1970 / 60).rounded())
        }.map(String.init) ?? "unknown-\(Int(observedAt.timeIntervalSince1970 / 86_400))"
        return "long|\(assessment.window.windowMinutes)|\(resetComponent)"
    }

    private func shouldPresent(_ alert: CodexUsagePaceAlert) -> Bool {
        persistedState.notifications[alert.notificationKey] == nil
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
