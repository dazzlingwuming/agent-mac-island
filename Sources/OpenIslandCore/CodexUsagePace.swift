import Foundation

/// A single persisted Codex usage reading used to measure usage over time.
///
/// The sample deliberately contains only aggregate quota metadata. It never
/// stores prompt, transcript, project, or session content.
public struct CodexUsagePaceSample: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var usedPercentage: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(
        capturedAt: Date,
        usedPercentage: Double,
        windowMinutes: Int,
        resetsAt: Date?
    ) {
        self.capturedAt = capturedAt
        self.usedPercentage = usedPercentage
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public enum CodexUsagePaceRisk: String, Codable, CaseIterable, Comparable, Sendable {
    case normal
    case attention
    case fast
    case critical

    public static func < (lhs: CodexUsagePaceRisk, rhs: CodexUsagePaceRisk) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .normal: 0
        case .attention: 1
        case .fast: 2
        case .critical: 3
        }
    }
}

public enum CodexUsagePaceDataStatus: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case missingCaptureTime
    case noRelevantWindows
}

/// The pace metrics for one quota window. Optional metrics require reset
/// metadata or at least one earlier compatible sample.
public struct CodexUsagePaceWindowAssessment: Codable, Equatable, Sendable {
    public var window: CodexUsageWindow
    public var risk: CodexUsagePaceRisk
    public var cycleProgress: Double?
    public var remainingDailyBudget: Double?
    public var todayUsedPercentage: Double?
    public var recentBurnRatePerDay: Double?
    public var estimatedHoursUntilSafetyReserve: Double?
    public var estimatedHoursUntilExhaustion: Double?
    public var didDetectResetOrDecrease: Bool

    public init(
        window: CodexUsageWindow,
        risk: CodexUsagePaceRisk,
        cycleProgress: Double?,
        remainingDailyBudget: Double?,
        todayUsedPercentage: Double?,
        recentBurnRatePerDay: Double?,
        estimatedHoursUntilSafetyReserve: Double?,
        estimatedHoursUntilExhaustion: Double?,
        didDetectResetOrDecrease: Bool
    ) {
        self.window = window
        self.risk = risk
        self.cycleProgress = cycleProgress
        self.remainingDailyBudget = remainingDailyBudget
        self.todayUsedPercentage = todayUsedPercentage
        self.recentBurnRatePerDay = recentBurnRatePerDay
        self.estimatedHoursUntilSafetyReserve = estimatedHoursUntilSafetyReserve
        self.estimatedHoursUntilExhaustion = estimatedHoursUntilExhaustion
        self.didDetectResetOrDecrease = didDetectResetOrDecrease
    }
}

/// A complete, display-agnostic decision for the current Codex quota snapshot.
public struct CodexUsagePaceEvaluation: Codable, Equatable, Sendable {
    public var status: CodexUsagePaceDataStatus
    public var capturedAt: Date?
    public var risk: CodexUsagePaceRisk
    public var longTerm: CodexUsagePaceWindowAssessment?
    public var shortTerm: CodexUsagePaceWindowAssessment?

    public init(
        status: CodexUsagePaceDataStatus,
        capturedAt: Date?,
        risk: CodexUsagePaceRisk,
        longTerm: CodexUsagePaceWindowAssessment?,
        shortTerm: CodexUsagePaceWindowAssessment?
    ) {
        self.status = status
        self.capturedAt = capturedAt
        self.risk = risk
        self.longTerm = longTerm
        self.shortTerm = shortTerm
    }

    public var isFresh: Bool {
        status == .fresh || status == .noRelevantWindows
    }
}

public struct CodexUsagePaceConfiguration: Codable, Equatable, Sendable {
    /// Quota percentage intentionally left unused at the end of a cycle.
    public var safetyReservePercentage: Double
    /// A stale snapshot cannot produce an alert.
    public var maximumSnapshotAge: TimeInterval
    /// Windows shorter than this cannot stand in for the multi-day quota.
    public var minimumLongTermWindowMinutes: Int
    public var preferredLongTermWindowMinutes: Int
    public var preferredShortTermWindowMinutes: Int
    public var maximumShortTermWindowMinutes: Int
    public var shortTermCriticalPercentage: Double
    /// Only nearby samples describe a current burst rather than historic pace.
    public var maximumBurnRateSampleAge: TimeInterval
    /// Ignore tiny polling intervals where a rounded percentage can jump by a
    /// whole point without representing a sustained consumption rate.
    public var minimumBurnRateSampleInterval: TimeInterval
    /// Rounded counters need at least this much growth before they describe a
    /// meaningful burst rather than a single percentage-point quantization.
    public var minimumBurnRateUsageIncreasePercentage: Double
    /// Allow early-cycle warnings once enough real time and rounded usage have
    /// accumulated to distinguish sustained consumption from a one-point jump.
    public var minimumElapsedCycleTimeForCumulativeRisk: TimeInterval
    public var minimumUsedPercentageForCumulativeRisk: Double

    public init(
        safetyReservePercentage: Double = 10,
        maximumSnapshotAge: TimeInterval = 10 * 60,
        minimumLongTermWindowMinutes: Int = 24 * 60,
        preferredLongTermWindowMinutes: Int = 7 * 24 * 60,
        preferredShortTermWindowMinutes: Int = 5 * 60,
        maximumShortTermWindowMinutes: Int = 6 * 60,
        shortTermCriticalPercentage: Double = 90,
        maximumBurnRateSampleAge: TimeInterval = 24 * 60 * 60,
        minimumBurnRateSampleInterval: TimeInterval = 15 * 60,
        minimumBurnRateUsageIncreasePercentage: Double = 2,
        minimumElapsedCycleTimeForCumulativeRisk: TimeInterval = 60 * 60,
        minimumUsedPercentageForCumulativeRisk: Double = 2
    ) {
        self.safetyReservePercentage = safetyReservePercentage
        self.maximumSnapshotAge = maximumSnapshotAge
        self.minimumLongTermWindowMinutes = minimumLongTermWindowMinutes
        self.preferredLongTermWindowMinutes = preferredLongTermWindowMinutes
        self.preferredShortTermWindowMinutes = preferredShortTermWindowMinutes
        self.maximumShortTermWindowMinutes = maximumShortTermWindowMinutes
        self.shortTermCriticalPercentage = shortTermCriticalPercentage
        self.maximumBurnRateSampleAge = maximumBurnRateSampleAge
        self.minimumBurnRateSampleInterval = minimumBurnRateSampleInterval
        self.minimumBurnRateUsageIncreasePercentage = minimumBurnRateUsageIncreasePercentage
        self.minimumElapsedCycleTimeForCumulativeRisk = minimumElapsedCycleTimeForCumulativeRisk
        self.minimumUsedPercentageForCumulativeRisk = minimumUsedPercentageForCumulativeRisk
    }

    public static let `default` = CodexUsagePaceConfiguration()
}

/// Evaluates quota pace without scheduling, persistence, UI, or notification
/// de-duplication. Those policy decisions belong in the app layer.
public enum CodexUsagePaceEvaluator {
    public static func evaluate(
        snapshot: CodexUsageSnapshot,
        samples: [CodexUsagePaceSample],
        now: Date = .now,
        calendar: Calendar = .current,
        configuration: CodexUsagePaceConfiguration = .default
    ) -> CodexUsagePaceEvaluation {
        guard let capturedAt = snapshot.capturedAt else {
            return CodexUsagePaceEvaluation(
                status: .missingCaptureTime,
                capturedAt: nil,
                risk: .normal,
                longTerm: nil,
                shortTerm: nil
            )
        }

        guard isFresh(capturedAt, now: now, maximumAge: configuration.maximumSnapshotAge) else {
            return CodexUsagePaceEvaluation(
                status: .stale,
                capturedAt: capturedAt,
                risk: .normal,
                longTerm: nil,
                shortTerm: nil
            )
        }

        let longTermWindow = snapshot.windows
            .filter { $0.windowMinutes >= configuration.minimumLongTermWindowMinutes }
            .min { lhs, rhs in
                windowDistance(lhs.windowMinutes, from: configuration.preferredLongTermWindowMinutes)
                    < windowDistance(rhs.windowMinutes, from: configuration.preferredLongTermWindowMinutes)
            }
        let shortTermWindow = snapshot.windows
            .filter { $0.windowMinutes > 0 && $0.windowMinutes <= configuration.maximumShortTermWindowMinutes }
            .min { lhs, rhs in
                windowDistance(lhs.windowMinutes, from: configuration.preferredShortTermWindowMinutes)
                    < windowDistance(rhs.windowMinutes, from: configuration.preferredShortTermWindowMinutes)
            }

        let longTerm = longTermWindow.map {
            assess(
                window: $0,
                isLongTerm: true,
                capturedAt: capturedAt,
                samples: samples,
                calendar: calendar,
                configuration: configuration
            )
        }
        let shortTerm = shortTermWindow.map {
            assess(
                window: $0,
                isLongTerm: false,
                capturedAt: capturedAt,
                samples: samples,
                calendar: calendar,
                configuration: configuration
            )
        }

        let risk = max(longTerm?.risk ?? .normal, shortTerm?.risk ?? .normal)
        return CodexUsagePaceEvaluation(
            status: longTerm == nil && shortTerm == nil ? .noRelevantWindows : .fresh,
            capturedAt: capturedAt,
            risk: risk,
            longTerm: longTerm,
            shortTerm: shortTerm
        )
    }

    private static func assess(
        window: CodexUsageWindow,
        isLongTerm: Bool,
        capturedAt: Date,
        samples: [CodexUsagePaceSample],
        calendar: Calendar,
        configuration: CodexUsagePaceConfiguration
    ) -> CodexUsagePaceWindowAssessment {
        let usedPercentage = clampedPercentage(window.usedPercentage)
        let currentSample = CodexUsagePaceSample(
            capturedAt: capturedAt,
            usedPercentage: usedPercentage,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt
        )
        let comparableSamples = compatibleSamples(
            samples,
            current: currentSample,
            window: window
        )
        let previousSample = comparableSamples.dropLast().last
        let didDetectResetOrDecrease = previousSample.map {
            usedPercentage < clampedPercentage($0.usedPercentage)
        } ?? false
        let burnRate = didDetectResetOrDecrease
            ? nil
            : recentBurnRate(
                samples: comparableSamples,
                current: currentSample,
                maximumAge: configuration.maximumBurnRateSampleAge,
                minimumInterval: configuration.minimumBurnRateSampleInterval,
                minimumIncrease: configuration.minimumBurnRateUsageIncreasePercentage
            )
        let todayUsedPercentage = todayIncrease(
            samples: comparableSamples,
            current: currentSample,
            calendar: calendar,
            didDetectResetOrDecrease: didDetectResetOrDecrease
        )
        let cycle = cycleMetrics(for: window, capturedAt: capturedAt)
        let estimatedHoursUntilSafetyReserve = burnRate.flatMap {
            hoursUntil(
                usageTarget: max(0, 100 - configuration.safetyReservePercentage),
                usedPercentage: usedPercentage,
                burnRatePerDay: $0
            )
        }
        let estimatedHoursUntilExhaustion = burnRate.flatMap {
            hoursUntil(usageTarget: 100, usedPercentage: usedPercentage, burnRatePerDay: $0)
        }

        let risk = risk(
            window: window,
            isLongTerm: isLongTerm,
            usedPercentage: usedPercentage,
            cycle: cycle,
            burnRatePerDay: burnRate,
            estimatedHoursUntilSafetyReserve: estimatedHoursUntilSafetyReserve,
            estimatedHoursUntilExhaustion: estimatedHoursUntilExhaustion,
            didDetectResetOrDecrease: didDetectResetOrDecrease,
            configuration: configuration
        )

        return CodexUsagePaceWindowAssessment(
            window: window,
            risk: risk,
            cycleProgress: cycle?.progress,
            remainingDailyBudget: cycle.map {
                let safeRemaining = max(0, 100 - configuration.safetyReservePercentage - usedPercentage)
                return safeRemaining / max($0.remainingDays, 1.0 / 24.0)
            },
            todayUsedPercentage: todayUsedPercentage,
            recentBurnRatePerDay: burnRate,
            estimatedHoursUntilSafetyReserve: estimatedHoursUntilSafetyReserve,
            estimatedHoursUntilExhaustion: estimatedHoursUntilExhaustion,
            didDetectResetOrDecrease: didDetectResetOrDecrease
        )
    }

    private struct CycleMetrics {
        var progress: Double
        var elapsedTime: TimeInterval
        var elapsedDays: Double
        var remainingDays: Double
    }

    private static func cycleMetrics(for window: CodexUsageWindow, capturedAt: Date) -> CycleMetrics? {
        guard window.windowMinutes > 0,
              let resetsAt = window.resetsAt,
              resetsAt > capturedAt else {
            return nil
        }

        let windowDuration = TimeInterval(window.windowMinutes * 60)
        let cycleStart = resetsAt.addingTimeInterval(-windowDuration)
        let elapsed = capturedAt.timeIntervalSince(cycleStart)
        guard elapsed >= 0 else {
            return nil
        }

        return CycleMetrics(
            progress: min(1, max(0, elapsed / windowDuration)),
            elapsedTime: elapsed,
            elapsedDays: elapsed / 86_400,
            remainingDays: resetsAt.timeIntervalSince(capturedAt) / 86_400
        )
    }

    private static func risk(
        window: CodexUsageWindow,
        isLongTerm: Bool,
        usedPercentage: Double,
        cycle: CycleMetrics?,
        burnRatePerDay: Double?,
        estimatedHoursUntilSafetyReserve: Double?,
        estimatedHoursUntilExhaustion: Double?,
        didDetectResetOrDecrease: Bool,
        configuration: CodexUsagePaceConfiguration
    ) -> CodexUsagePaceRisk {
        if !isLongTerm {
            return usedPercentage >= configuration.shortTermCriticalPercentage ? .critical : .normal
        }

        // A declining counter is normally a reset. Wait for the next positive
        // pair rather than turning a reset into a misleading warning.
        guard !didDetectResetOrDecrease, let cycle else {
            return .normal
        }

        let remainingHours = cycle.remainingDays * 24
        guard remainingHours > 0 else {
            return .normal
        }

        let safetyLimit = max(0, 100 - configuration.safetyReservePercentage)
        if usedPercentage >= safetyLimit, remainingHours >= 6 {
            return .critical
        }

        if let estimatedHoursUntilExhaustion {
            if estimatedHoursUntilExhaustion < max(6, remainingHours * 0.4) {
                return .critical
            }
            if estimatedHoursUntilExhaustion < remainingHours * 0.75 {
                return .fast
            }
        }

        if let estimatedHoursUntilSafetyReserve,
           estimatedHoursUntilSafetyReserve < remainingHours {
            return .attention
        }

        // A newly reset seven-day window can already reveal an unsafe pace
        // before a 15-minute sample pair exists. One elapsed hour plus at least
        // two rounded percentage points is enough signal, while a lone 0→1%
        // jump remains below the noise floor.
        guard cycle.elapsedTime >= configuration.minimumElapsedCycleTimeForCumulativeRisk,
              usedPercentage >= configuration.minimumUsedPercentageForCumulativeRisk,
              cycle.elapsedDays > 0 else {
            return .normal
        }

        let averageBurnRatePerDay = usedPercentage / cycle.elapsedDays
        guard averageBurnRatePerDay > 0 else {
            return .normal
        }

        guard let hoursUntilExhaustion = hoursUntil(
            usageTarget: 100,
            usedPercentage: usedPercentage,
            burnRatePerDay: averageBurnRatePerDay
        ), let hoursUntilSafetyReserve = hoursUntil(
            usageTarget: safetyLimit,
            usedPercentage: usedPercentage,
            burnRatePerDay: averageBurnRatePerDay
        ) else {
            return .normal
        }

        if hoursUntilExhaustion < max(6, remainingHours * 0.4) {
            return .critical
        }
        if hoursUntilExhaustion < remainingHours * 0.75 {
            return .fast
        }
        if hoursUntilSafetyReserve < remainingHours {
            return .attention
        }

        _ = burnRatePerDay
        return .normal
    }

    private static func compatibleSamples(
        _ samples: [CodexUsagePaceSample],
        current: CodexUsagePaceSample,
        window: CodexUsageWindow
    ) -> [CodexUsagePaceSample] {
        let compatible = samples.filter { sample in
            guard sample.windowMinutes == window.windowMinutes,
                  sample.capturedAt <= current.capturedAt else {
                return false
            }

            switch (sample.resetsAt, current.resetsAt) {
            case let (.some(lhs), .some(rhs)):
                return abs(lhs.timeIntervalSince(rhs)) < 1
            case (.none, .none):
                return true
            default:
                return false
            }
        }

        let sorted = (compatible + [current]).sorted { $0.capturedAt < $1.capturedAt }
        return sorted.reduce(into: []) { result, sample in
            if result.last?.capturedAt == sample.capturedAt {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
    }

    private static func recentBurnRate(
        samples: [CodexUsagePaceSample],
        current: CodexUsagePaceSample,
        maximumAge: TimeInterval,
        minimumInterval: TimeInterval,
        minimumIncrease: Double
    ) -> Double? {
        guard let baseline = samples.dropLast().first(where: { sample in
            let interval = current.capturedAt.timeIntervalSince(sample.capturedAt)
            return interval >= minimumInterval && interval <= maximumAge
        }) else {
            return nil
        }

        let interval = current.capturedAt.timeIntervalSince(baseline.capturedAt)
        guard interval >= minimumInterval, interval <= maximumAge else {
            return nil
        }

        let increase = clampedPercentage(current.usedPercentage) - clampedPercentage(baseline.usedPercentage)
        guard increase >= minimumIncrease else {
            return nil
        }

        return increase / (interval / 86_400)
    }

    private static func todayIncrease(
        samples: [CodexUsagePaceSample],
        current: CodexUsagePaceSample,
        calendar: Calendar,
        didDetectResetOrDecrease: Bool
    ) -> Double? {
        guard !didDetectResetOrDecrease else {
            return nil
        }

        let startOfDay = calendar.startOfDay(for: current.capturedAt)
        guard let earliestToday = samples.first(where: { $0.capturedAt >= startOfDay }) else {
            return nil
        }

        let increase = clampedPercentage(current.usedPercentage) - clampedPercentage(earliestToday.usedPercentage)
        return increase >= 0 ? increase : nil
    }

    private static func hoursUntil(
        usageTarget: Double,
        usedPercentage: Double,
        burnRatePerDay: Double
    ) -> Double? {
        guard burnRatePerDay > 0 else {
            return nil
        }

        return max(0, usageTarget - usedPercentage) / burnRatePerDay * 24
    }

    private static func isFresh(_ capturedAt: Date, now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= maximumAge
    }

    private static func windowDistance(_ windowMinutes: Int, from preferredMinutes: Int) -> Int {
        abs(windowMinutes - preferredMinutes)
    }

    private static func clampedPercentage(_ percentage: Double) -> Double {
        min(100, max(0, percentage))
    }
}
