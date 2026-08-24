import Testing
@testable import OpenIslandApp

struct IslandDebugScenarioTests {
    @Test
    func allDebugScenarioSessionsAreDemoSessions() {
        for scenario in IslandDebugScenario.allCases {
            let snapshot = scenario.snapshot()
            #expect(snapshot.sessions.allSatisfy { $0.origin == .demo })
        }
    }

    @Test
    func usagePaceScenarioIsAStandaloneNotificationSurface() throws {
        let snapshot = IslandDebugScenario.usagePaceAlert.snapshot()
        let alert = try #require(snapshot.islandSurface.codexUsageAlert)

        #expect(snapshot.notchStatus == .opened)
        #expect(snapshot.notchOpenReason == .notification)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.selectedSessionID == nil)
        #expect(alert.severity == .fast)
    }
}
