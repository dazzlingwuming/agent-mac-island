import Foundation
import Testing
@testable import OpenIslandCore

struct CodexUsagePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sevenDays = 7 * 24 * 60
    private let fiveHours = 5 * 60

    @Test
    func normalLongTermPaceUsesWindowMinutesRatherThanWindowKey() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [
                window(key: "secondary", used: 10, minutes: fiveHours, resetsAt: now.addingTimeInterval(3 * 60 * 60)),
                window(key: "primary", used: 20, minutes: sevenDays, resetsAt: reset),
            ]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.status == .fresh)
        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm?.window.key == "primary")
        #expect(approximatelyEqual(evaluation.longTerm?.remainingDailyBudget, 14))
        #expect(evaluation.shortTerm?.window.key == "secondary")
    }

    @Test
    func twoDaysOfHeavyLongTermUseIsFast() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "primary", used: 40, minutes: sevenDays, resetsAt: reset)]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk == .fast)
        #expect(approximatelyEqual(evaluation.longTerm?.cycleProgress, 2.0 / 7.0))
        #expect(approximatelyEqual(evaluation.longTerm?.remainingDailyBudget, 8))
    }

    @Test
    func recentBurstEscalatesEvenWhenCumulativeUseLookedSafe() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 34, minutes: sevenDays, resetsAt: reset)]
        )
        let samples = [
            sample(hoursAgo: 3, used: 20, minutes: sevenDays, resetsAt: reset),
        ]

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: samples, now: now)

        #expect(evaluation.risk == .critical)
        #expect(approximatelyEqual(evaluation.longTerm?.recentBurnRatePerDay, 112))
        #expect(approximatelyEqual(evaluation.longTerm?.estimatedHoursUntilExhaustion, 14.142857142857142))
        #expect(approximatelyEqual(evaluation.longTerm?.todayUsedPercentage, 14))
    }

    @Test
    func roundedTwoMinuteJumpDoesNotBecomeAnImpossibleDailyBurnRate() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 22, minutes: sevenDays, resetsAt: reset)]
        )
        let samples = [
            sample(hoursAgo: 2, used: 21, minutes: sevenDays, resetsAt: reset),
            sample(hoursAgo: 2.0 / 60.0, used: 21, minutes: sevenDays, resetsAt: reset),
        ]

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: samples, now: now)

        #expect(evaluation.risk == .normal)
        #expect(approximatelyEqual(evaluation.longTerm?.recentBurnRatePerDay, 12))
    }

    @Test
    func threePercentInFirstSeventyFiveMinutesTriggersEarlyCycleWarning() {
        let reset = now.addingTimeInterval((7 * 24 * 60 * 60) - (75 * 60))
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 3, minutes: sevenDays, resetsAt: reset)]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk > .normal)
        #expect(evaluation.longTerm?.recentBurnRatePerDay == nil)
        #expect(approximatelyEqual(evaluation.longTerm?.cycleProgress, 75.0 / (7 * 24 * 60)))
    }

    @Test
    func oneRoundedPercentEarlyInCycleStaysBelowNoiseFloor() {
        let reset = now.addingTimeInterval((7 * 24 * 60 * 60) - (75 * 60))
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 1, minutes: sevenDays, resetsAt: reset)]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk == .normal)
    }

    @Test
    func threePercentBeforeOneHourStaysInWarmup() {
        let reset = now.addingTimeInterval((7 * 24 * 60 * 60) - (45 * 60))
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 3, minutes: sevenDays, resetsAt: reset)]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk == .normal)
    }

    @Test
    func onePointJumpAfterFifteenMinutesStaysBelowBurnRateNoiseFloor() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 1, minutes: sevenDays, resetsAt: reset)]
        )
        let samples = [sample(hoursAgo: 0.25, used: 0, minutes: sevenDays, resetsAt: reset)]

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: samples, now: now)

        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm?.recentBurnRatePerDay == nil)
    }

    @Test
    func threePointJumpAfterFifteenMinutesRemainsActionable() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 3, minutes: sevenDays, resetsAt: reset)]
        )
        let samples = [sample(hoursAgo: 0.25, used: 0, minutes: sevenDays, resetsAt: reset)]

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: samples, now: now)

        #expect(evaluation.risk > .normal)
        #expect(approximatelyEqual(evaluation.longTerm?.recentBurnRatePerDay, 288))
    }

    @Test
    func staleSnapshotNeverProducesAnAlert() {
        let capturedAt = now.addingTimeInterval(-11 * 60)
        let snapshot = snapshot(
            capturedAt: capturedAt,
            windows: [window(key: "secondary", used: 90, minutes: sevenDays, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.status == .stale)
        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm == nil)
    }

    @Test
    func decliningCounterIsTreatedAsResetAndDoesNotAlert() {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 20, minutes: sevenDays, resetsAt: reset)]
        )
        let samples = [
            sample(hoursAgo: 2, used: 80, minutes: sevenDays, resetsAt: reset),
        ]

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: samples, now: now)

        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm?.didDetectResetOrDecrease == true)
        #expect(evaluation.longTerm?.recentBurnRatePerDay == nil)
    }

    @Test
    func missingResetMetadataDoesNotInferAQuotaWarning() {
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "secondary", used: 95, minutes: sevenDays, resetsAt: nil)]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm?.remainingDailyBudget == nil)
    }

    @Test
    func fiveHourWindowAtNinetyPercentIsCritical() {
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "primary", used: 90, minutes: fiveHours, resetsAt: now.addingTimeInterval(60 * 60))]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.risk == .critical)
        #expect(evaluation.longTerm == nil)
        #expect(evaluation.shortTerm?.risk == .critical)
    }

    @Test
    func noLongTermWindowStaysNormalWithoutPretendingShortWindowIsSevenDays() {
        let snapshot = snapshot(
            capturedAt: now,
            windows: [window(key: "primary", used: 50, minutes: 60, resetsAt: now.addingTimeInterval(30 * 60))]
        )

        let evaluation = CodexUsagePaceEvaluator.evaluate(snapshot: snapshot, samples: [], now: now)

        #expect(evaluation.status == .fresh)
        #expect(evaluation.risk == .normal)
        #expect(evaluation.longTerm == nil)
        #expect(evaluation.shortTerm?.window.windowMinutes == 60)
    }

    private func snapshot(capturedAt: Date, windows: [CodexUsageWindow]) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            sourceFilePath: "/tmp/rollout.jsonl",
            capturedAt: capturedAt,
            windows: windows
        )
    }

    private func window(key: String, used: Double, minutes: Int, resetsAt: Date?) -> CodexUsageWindow {
        CodexUsageWindow(
            key: key,
            label: key,
            usedPercentage: used,
            leftPercentage: 100 - used,
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }

    private func sample(hoursAgo: Double, used: Double, minutes: Int, resetsAt: Date?) -> CodexUsagePaceSample {
        CodexUsagePaceSample(
            capturedAt: now.addingTimeInterval(-hoursAgo * 60 * 60),
            usedPercentage: used,
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }

    private func approximatelyEqual(_ value: Double?, _ expected: Double, tolerance: Double = 0.000_001) -> Bool {
        guard let value else {
            return false
        }

        return abs(value - expected) <= tolerance
    }
}
