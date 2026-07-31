import Foundation
import Testing
@testable import OpenIslandApp

struct HarnessLaunchConfigurationTests {
    @Test
    func defaultsMatchNormalAppLaunch() {
        let configuration = HarnessLaunchConfiguration(environment: [:])

        #expect(configuration.scenario == nil)
        #expect(!configuration.presentOverlay)
        #expect(configuration.shouldStartBridge)
        #expect(configuration.shouldPerformBootAnimation)
        #expect(configuration.showOnlyForNotifications == nil)
        #expect(!configuration.exerciseHiddenOverlayHover)
        #expect(!configuration.exerciseHiddenOverlayClick)
        #expect(!configuration.expectHiddenHoverAtCapture)
        #expect(!configuration.exercisePointerExitAutoHide)
        #expect(!configuration.exercisePointerExitAutoHideCancellation)
        #expect(!configuration.exerciseIdleSessionCleanup)
        #expect(configuration.captureDelay == nil)
        #expect(configuration.autoExitAfter == nil)
        #expect(configuration.artifactDirectoryURL == nil)
    }

    @Test
    func parsesScenarioFlagsAndAutoExit() {
        let configuration = HarnessLaunchConfiguration(
            environment: [
                "OPEN_ISLAND_HARNESS_SCENARIO": "approvalcard",
                "OPEN_ISLAND_HARNESS_PRESENT_OVERLAY": "true",
                "OPEN_ISLAND_HARNESS_START_BRIDGE": "no",
                "OPEN_ISLAND_HARNESS_BOOT_ANIMATION": "off",
                "OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS": "yes",
                "OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_HOVER": "1",
                "OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_CLICK": "true",
                "OPEN_ISLAND_HARNESS_EXPECT_HIDDEN_HOVER_AT_CAPTURE": "on",
                "OPEN_ISLAND_HARNESS_EXERCISE_POINTER_EXIT_AUTO_HIDE": "true",
                "OPEN_ISLAND_HARNESS_EXERCISE_POINTER_EXIT_AUTO_HIDE_CANCELLATION": "yes",
                "OPEN_ISLAND_HARNESS_EXERCISE_IDLE_SESSION_CLEANUP": "on",
                "OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS": "1.5",
                "OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS": "2.5",
                "OPEN_ISLAND_HARNESS_ARTIFACT_DIR": "/tmp/open-island-artifacts",
            ]
        )

        #expect(configuration.scenario == .approvalCard)
        #expect(configuration.presentOverlay)
        #expect(!configuration.shouldStartBridge)
        #expect(!configuration.shouldPerformBootAnimation)
        #expect(configuration.showOnlyForNotifications == true)
        #expect(configuration.exerciseHiddenOverlayHover)
        #expect(configuration.exerciseHiddenOverlayClick)
        #expect(configuration.expectHiddenHoverAtCapture)
        #expect(configuration.exercisePointerExitAutoHide)
        #expect(configuration.exercisePointerExitAutoHideCancellation)
        #expect(configuration.exerciseIdleSessionCleanup)
        #expect(configuration.captureDelay == 1.5)
        #expect(configuration.autoExitAfter == 2.5)
        #expect(configuration.artifactDirectoryURL?.path == "/tmp/open-island-artifacts")
    }

    @Test
    func ignoresInvalidInputs() {
        let configuration = HarnessLaunchConfiguration(
            environment: [
                "OPEN_ISLAND_HARNESS_SCENARIO": "missing",
                "OPEN_ISLAND_HARNESS_PRESENT_OVERLAY": "unexpected",
                "OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS": "0",
                "OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS": "-1",
                "OPEN_ISLAND_HARNESS_ARTIFACT_DIR": "   ",
            ]
        )

        #expect(configuration.scenario == nil)
        #expect(!configuration.presentOverlay)
        #expect(configuration.captureDelay == nil)
        #expect(configuration.autoExitAfter == nil)
        #expect(configuration.artifactDirectoryURL == nil)
    }
}
