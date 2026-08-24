import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct CodexUsagePaceCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sevenDays = 7 * 24 * 60

    @Test
    func storeRoundTripsOnlyNumericQuotaState() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = CodexUsagePaceStore(fileURL: url)
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let state = CodexUsagePacePersistedState(
            samples: [
                CodexUsagePaceSample(
                    capturedAt: now,
                    usedPercentage: 32,
                    windowMinutes: sevenDays,
                    resetsAt: reset
                ),
            ],
            notifications: [
                "long|10080|reset": CodexUsagePaceNotificationRecord(risk: .fast, notifiedAt: now),
            ],
            planType: "pro",
            limitID: "codex"
        )

        try store.save(state)

        #expect(try store.load() == state)
        let encoded = try String(contentsOf: url, encoding: .utf8)
        #expect(!encoded.localizedCaseInsensitiveContains("prompt"))
        #expect(!encoded.localizedCaseInsensitiveContains("transcript"))
        #expect(!encoded.contains("sourceFilePath"))
    }

    @Test
    func versionOneStoreRemainsReadableAndIsRewrittenAsVersionTwo() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = CodexUsagePacePersistedState(
            samples: [
                CodexUsagePaceSample(
                    capturedAt: now,
                    usedPercentage: 20,
                    windowMinutes: sevenDays,
                    resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
                ),
            ],
            notifications: [
                "long|10080|legacy-reset": CodexUsagePaceNotificationRecord(
                    risk: .fast,
                    notifiedAt: now
                ),
            ],
            planType: "pro",
            limitID: "codex"
        )
        let legacyData = try JSONEncoder().encode(
            LegacyDocument(version: 1, state: state)
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: url)

        let store = CodexUsagePaceStore(fileURL: url)
        #expect(try store.load() == state)

        try store.save(state)
        let rewritten = try JSONDecoder().decode(
            VersionProbe.self,
            from: Data(contentsOf: url)
        )
        #expect(rewritten.version == 2)
    }

    @Test
    func firstFastCandidateIsReturned() {
        let store = makeStore()
        let coordinator = CodexUsagePaceCoordinator(store: store)

        let alert = coordinator.ingest(fastSnapshot(), alertsEnabled: true, now: now)

        #expect(alert?.risk == .fast)
        #expect(alert?.severity == .fast)
        #expect(alert?.recommendedDailyPercentage == 8)
    }

    @Test
    func candidateRetriesUntilPresentationIsRecorded() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let snapshot = fastSnapshot()

        let first = coordinator.ingest(snapshot, alertsEnabled: true, now: now)
        let retry = coordinator.ingest(snapshot, alertsEnabled: true, now: now)

        #expect(first?.id == retry?.id)
        #expect(retry?.risk == .fast)
    }

    @Test
    func recordingPresentationSuppressesSameRiskInTheSamePeriod() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let snapshot = fastSnapshot()

        let alert = coordinator.ingest(snapshot, alertsEnabled: true, now: now)
        coordinator.recordPresentation(of: try! #require(alert))

        #expect(coordinator.ingest(snapshot, alertsEnabled: true, now: now) == nil)
    }

    @Test
    func aNewIntegerPercentageCanNotifyAgainInTheSamePeriod() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let fast = snapshot(capturedAt: now, used: 40, resetsAt: reset)
        let first = coordinator.ingest(fast, alertsEnabled: true, now: now)
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(2 * 60)
        let critical = snapshot(capturedAt: later, used: 90, resetsAt: reset)
        let escalated = coordinator.ingest(critical, alertsEnabled: true, now: later)

        #expect(escalated?.risk == .critical)
        #expect(escalated?.usedPercentage == 90)
        #expect(escalated?.notificationKey != first?.notificationKey)
    }

    @Test
    func aRiskEscalationAtTheSamePercentageDoesNotNotifyAgain() throws {
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let criticalSnapshot = snapshot(capturedAt: now, used: 90, resetsAt: reset)
        let keyStore = makeStore()
        let keyCoordinator = CodexUsagePaceCoordinator(store: keyStore)
        let criticalCandidate = try #require(
            keyCoordinator.ingest(criticalSnapshot, alertsEnabled: true, now: now)
        )

        let store = makeStore()
        try store.save(CodexUsagePacePersistedState(
            notifications: [
                criticalCandidate.notificationKey: CodexUsagePaceNotificationRecord(
                    risk: .fast,
                    notifiedAt: now
                ),
            ],
            planType: "pro",
            limitID: "codex"
        ))
        let coordinator = CodexUsagePaceCoordinator(store: store)

        #expect(coordinator.ingest(
            criticalSnapshot,
            alertsEnabled: true,
            now: now
        ) == nil)
    }

    @Test
    func normalPaceStillNotifiesForEveryNewIntegerPercentage() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let first = coordinator.ingest(
            snapshot(capturedAt: now, used: 20, resetsAt: reset),
            alertsEnabled: true,
            now: now
        )
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(2 * 60)
        let next = coordinator.ingest(
            snapshot(capturedAt: later, used: 21, resetsAt: reset),
            alertsEnabled: true,
            now: later
        )

        #expect(first?.risk == .normal)
        #expect(next?.risk == .normal)
        #expect(next?.usedPercentage == 21)
        #expect(next?.notificationKey != first?.notificationKey)
    }

    @Test
    func percentageJumpReturnsOnlyTheCurrentObservedPercentage() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let first = coordinator.ingest(
            snapshot(capturedAt: now, used: 20, resetsAt: reset),
            alertsEnabled: true,
            now: now
        )
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(2 * 60)
        let jumped = coordinator.ingest(
            snapshot(capturedAt: later, used: 23, resetsAt: reset),
            alertsEnabled: true,
            now: later
        )

        #expect(jumped?.usedPercentage == 23)
        #expect(jumped?.previousUsedPercentage == 20)
        #expect(jumped?.notificationKey.contains("used-23") == true)
    }

    @Test
    func aDecreasedPercentageDoesNotCreateANewCandidateInTheSamePeriod() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let first = coordinator.ingest(
            snapshot(capturedAt: now, used: 20, resetsAt: reset),
            alertsEnabled: true,
            now: now
        )
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(2 * 60)
        let decreased = coordinator.ingest(
            snapshot(capturedAt: later, used: 19, resetsAt: reset),
            alertsEnabled: true,
            now: later
        )

        #expect(decreased == nil)
    }

    @Test
    func aChangedResetTimeStartsANewNotificationPeriod() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let firstReset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let first = coordinator.ingest(
            snapshot(capturedAt: now, used: 40, resetsAt: firstReset),
            alertsEnabled: true,
            now: now
        )
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(60 * 60)
        let secondReset = later.addingTimeInterval(5 * 24 * 60 * 60)
        let newPeriod = coordinator.ingest(
            snapshot(capturedAt: later, used: 40, resetsAt: secondReset),
            alertsEnabled: true,
            now: later
        )

        #expect(newPeriod?.risk == .fast)
        #expect(newPeriod?.notificationKey != first?.notificationKey)
    }

    @Test
    func oneSecondResetTimestampJitterDoesNotCreateANewPeriod() {
        let coordinator = CodexUsagePaceCoordinator(store: makeStore())
        let reset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let first = coordinator.ingest(
            snapshot(capturedAt: now, used: 40, resetsAt: reset),
            alertsEnabled: true,
            now: now
        )
        coordinator.recordPresentation(of: try! #require(first))

        let later = now.addingTimeInterval(2 * 60)
        let jittered = coordinator.ingest(
            snapshot(
                capturedAt: later,
                used: 40,
                resetsAt: reset.addingTimeInterval(1)
            ),
            alertsEnabled: true,
            now: later
        )

        #expect(jittered == nil)
    }

    @Test
    func disabledAlertsStillPersistFreshSamplesWithoutReturningACandidate() throws {
        let store = makeStore()
        let coordinator = CodexUsagePaceCoordinator(store: store)

        #expect(coordinator.ingest(fastSnapshot(), alertsEnabled: false, now: now) == nil)

        let state = try store.load()
        #expect(state.samples.count == 1)
        #expect(state.notifications.isEmpty)
    }

    @Test
    func staleSnapshotDoesNotPersistOrNotify() throws {
        let store = makeStore()
        let coordinator = CodexUsagePaceCoordinator(store: store)
        let staleAt = now.addingTimeInterval(-11 * 60)

        #expect(coordinator.ingest(
            snapshot(capturedAt: staleAt, used: 90, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
            alertsEnabled: true,
            now: now
        ) == nil)

        let state = try store.load()
        #expect(state.samples.isEmpty)
        #expect(state.notifications.isEmpty)
    }

    @Test
    func modelSpecificPoolDoesNotEraseOrdinaryCodexHistory() throws {
        let store = makeStore()
        let coordinator = CodexUsagePaceCoordinator(store: store)
        _ = coordinator.ingest(fastSnapshot(), alertsEnabled: false, now: now)

        let modelSpecificSnapshot = CodexUsageSnapshot(
            sourceFilePath: "/private/tmp/spark-rollout.jsonl",
            capturedAt: now.addingTimeInterval(2 * 60),
            planType: "pro",
            limitID: "codex_bengalfox",
            windows: [
                CodexUsageWindow(
                    key: "secondary",
                    label: "7d",
                    usedPercentage: 0,
                    leftPercentage: 100,
                    windowMinutes: sevenDays,
                    resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60)
                ),
            ]
        )

        #expect(coordinator.ingest(
            modelSpecificSnapshot,
            alertsEnabled: true,
            now: now.addingTimeInterval(2 * 60)
        ) == nil)

        let state = try store.load()
        #expect(state.limitID == "codex")
        #expect(state.samples.count == 1)
        #expect(state.samples.first?.usedPercentage == 40)
    }

    private func fastSnapshot() -> CodexUsageSnapshot {
        snapshot(
            capturedAt: now,
            used: 40,
            resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
        )
    }

    private func snapshot(capturedAt: Date, used: Double, resetsAt: Date) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            sourceFilePath: "/private/tmp/rollout.jsonl",
            capturedAt: capturedAt,
            planType: "pro",
            limitID: "codex",
            windows: [
                CodexUsageWindow(
                    key: "secondary",
                    label: "7d",
                    usedPercentage: used,
                    leftPercentage: 100 - used,
                    windowMinutes: sevenDays,
                    resetsAt: resetsAt
                ),
            ]
        )
    }

    private func makeStore() -> CodexUsagePaceStore {
        CodexUsagePaceStore(fileURL: temporaryStoreURL())
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-usage-pace-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private struct LegacyDocument: Codable {
        let version: Int
        let state: CodexUsagePacePersistedState
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }
}
