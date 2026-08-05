import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct SessionDiscoveryCoordinatorTests {
    @Test
    func codexRediscoveryAllowsOnlyOneInFlightScanAndRestartsAfterCompletion() async {
        let operation = BlockingRediscoveryOperation()
        let coordinator = SessionDiscoveryCoordinator(
            codexRediscoveryOperation: { operation.run() }
        )
        let start = Date.now

        coordinator.rediscoverCodexAppSessionsIfNeeded(now: start)
        await operation.waitForStart(count: 1)

        // A monitor tick after the throttle interval still cannot launch a
        // second detached scan while the first scan owns the single-flight.
        coordinator.rediscoverCodexAppSessionsIfNeeded(now: start.addingTimeInterval(20))
        #expect(operation.callCount == 1)

        operation.releaseOneScan()
        await operation.waitForCompletion(count: 1)

        // The detached operation can return just before its MainActor task
        // clears the gate. Mirror subsequent maintenance ticks instead of
        // assuming those two scheduler events are atomic.
        for _ in 0..<100 where operation.callCount < 2 {
            coordinator.rediscoverCodexAppSessionsIfNeeded(now: Date.now.addingTimeInterval(20))
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(operation.callCount == 2)
        operation.releaseOneScan()
        await operation.waitForCompletion(count: 2)
    }
}

private final class BlockingRediscoveryOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var starts = 0
    private var completions = 0

    var callCount: Int {
        lock.withLock { starts }
    }

    func run() -> [CodexTrackedSessionRecord] {
        lock.withLock { starts += 1 }
        release.wait()
        lock.withLock { completions += 1 }
        return []
    }

    func releaseOneScan() {
        release.signal()
    }

    func waitForStart(count: Int) async {
        await waitUntil { self.lock.withLock { self.starts >= count } }
    }

    func waitForCompletion(count: Int) async {
        await waitUntil { self.lock.withLock { self.completions >= count } }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for rediscovery test operation.")
    }
}
