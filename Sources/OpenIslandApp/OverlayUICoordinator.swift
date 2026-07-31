import AppKit
import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class OverlayUICoordinator {

    private static let notificationSurfaceAutoCollapseDelay: TimeInterval = 10
    static let pointerExitAutoHideDelay: TimeInterval = 1.5

    var notchStatus: NotchStatus = .closed
    var notchOpenReason: NotchOpenReason?
    var islandSurface: IslandSurface = .sessionList()
    var isOverlayVisible: Bool { notchStatus != .closed }
    var isOverlayPanelVisible: Bool { overlayPanelController.isVisuallyVisible }
    var isOverlayPanelOrdered: Bool { overlayPanelController.isOrdered }
    var isOverlayPanelClickThrough: Bool { overlayPanelController.isClickThrough }
    var overlayPanelAcceptsMouseMovedEvents: Bool {
        overlayPanelController.acceptsMouseMovedEvents
    }
    var overlayPanelAlphaValue: CGFloat { overlayPanelController.alphaValue }
    var isOverlayPanelAvailableAcrossSpaces: Bool {
        overlayPanelController.isAvailableAcrossSpaces
    }
    var hasPendingHoverOpen: Bool { overlayPanelController.hasPendingHoverOpen }

    var showOnlyForNotifications = false {
        didSet {
            guard showOnlyForNotifications != oldValue else { return }
            cancelPointerExitAutoHide()
            updateClosedOverlayVisibility()
        }
    }

    var overlayDisplayOptions: [OverlayDisplayOption] = []
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics?

    var overlayDisplaySelectionID = OverlayDisplayOption.automaticID {
        didSet {
            guard overlayDisplaySelectionID != oldValue else {
                return
            }
            persistOverlayDisplayPreference()
            refreshOverlayPlacement()
        }
    }

    @ObservationIgnored
    weak var appModel: AppModel?

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var activeIslandCardSessionAccessor: (() -> AgentSession?)?

    @ObservationIgnored
    var isSoundMutedAccessor: (() -> Bool)?

    @ObservationIgnored
    var ignoresPointerExitAccessor: (() -> Bool)?

    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor?

    @ObservationIgnored
    let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private var screenParametersObserver: NSObjectProtocol?

    @ObservationIgnored
    private var activeSpaceObserver: NSObjectProtocol?

    @ObservationIgnored
    private var overlayTransitionGeneration: UInt64 = 0

    @ObservationIgnored
    private var notificationAutoCollapseTask: Task<Void, Never>?

    @ObservationIgnored
    private var pointerExitAutoHideTask: Task<Void, Never>?

    var hasPendingNotificationAutoCollapse: Bool {
        notificationAutoCollapseTask != nil
    }

    var hasPendingPointerExitAutoHide: Bool {
        pointerExitAutoHideTask != nil
    }

    @ObservationIgnored
    private var autoCollapseSurfaceHasBeenEntered = false

    @ObservationIgnored
    private var isPointerInsideIslandSurface = false

    /// Kept for API compatibility; always false now that the window never
    /// resizes and close transitions are pure SwiftUI.
    var isCloseTransitionPending: Bool { false }

    private var activeIslandCardSession: AgentSession? {
        activeIslandCardSessionAccessor?()
    }

    private var isSoundMuted: Bool {
        isSoundMutedAccessor?() ?? false
    }

    private var ignoresPointerExitDuringHarness: Bool {
        ignoresPointerExitAccessor?() ?? false
    }

    private var preferredOverlayScreenID: String? {
        overlayDisplaySelectionID == OverlayDisplayOption.automaticID
            ? nil
            : overlayDisplaySelectionID
    }

    // MARK: - Initialization

    func restoreDisplayPreference() {
        overlayDisplaySelectionID = UserDefaults.standard.string(
            forKey: "overlay.display.preference"
        ) ?? OverlayDisplayOption.automaticID
    }

    /// Re-syncs the cached display options and the target panel placement
    /// whenever macOS reports a screen configuration change (hotplug,
    /// arrangement change, sleep/wake). Without this, the picker list keeps
    /// stale entries after disconnect, and a saved preference whose
    /// `CGDirectDisplayID` gets reused for a different physical display can
    /// silently route the island to the wrong screen.
    func startObservingDisplayChanges() {
        if screenParametersObserver == nil {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshOverlayDisplayConfiguration()
                }
            }
        }

        if activeSpaceObserver == nil {
            activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reassertOverlayOnActiveSpace()
                }
            }
        }
    }

    isolated deinit {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        notificationAutoCollapseTask?.cancel()
        pointerExitAutoHideTask?.cancel()
    }

    // MARK: - Overlay transitions

    func toggleOverlay() {
        if notchStatus == .closed {
            notchOpen(reason: .click)
        } else {
            notchClose()
        }
    }

    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) {
        transitionOverlay(
            to: .opened,
            reason: reason,
            surface: surface,
            interactive: true,
            beforeTransition: { [weak self] in
                self?.cancelPointerExitAutoHide()
            },
            afterStateChange: { [weak self] in
                guard let self else { return }
                self.autoCollapseSurfaceHasBeenEntered = false
                self.isPointerInsideIslandSurface = false
                self.updateNotificationAutoCollapse()
            },
            onPlacementResolved: { [weak self] in
                guard let self, let overlayPlacementDiagnostics else { return }
                self.onStatusMessage?("Overlay showing on \(overlayPlacementDiagnostics.targetScreenName) as \(overlayPlacementDiagnostics.modeDescription.lowercased()).")
            }
        )
    }

    func notchClose() {
        transitionOverlay(
            to: .closed,
            reason: nil,
            surface: .sessionList(),
            interactive: false,
            beforeTransition: { [weak self] in
                self?.cancelPointerExitAutoHide()
                self?.notificationAutoCollapseTask?.cancel()
                self?.notificationAutoCollapseTask = nil
            },
            afterStateChange: { [weak self] in
                guard let self else { return }
                self.autoCollapseSurfaceHasBeenEntered = false
                self.isPointerInsideIslandSurface = false
                self.appModel?.measuredNotificationContentHeight = 0
                self.updateClosedOverlayVisibility()
            }
        )
    }

    /// Coordinates overlay transitions.
    ///
    /// The window stays at a fixed (opened) size at all times.  All visual
    /// transitions — shape morphing, content fade, corner radius — are
    /// driven purely by SwiftUI `.animation()` modifiers reacting to
    /// `notchStatus` changes.  No AppKit animation, no window resize.
    private func transitionOverlay(
        to status: NotchStatus,
        reason: NotchOpenReason?,
        surface: IslandSurface,
        interactive: Bool,
        beforeTransition: (() -> Void)?,
        afterStateChange: (() -> Void)? = nil,
        onPlacementResolved: (() -> Void)? = nil
    ) {
        beforeTransition?()

        overlayTransitionGeneration &+= 1

        // Reset measured notification height when the surface changes so stale
        // measurements from a previous notification don't mis-size the new one.
        if surface != islandSurface {
            appModel?.measuredNotificationContentHeight = 0
        }

        islandSurface = surface
        notchOpenReason = reason
        notchStatus = status
        overlayPanelController.setInteractive(interactive)

        if status == .opened, let appModel {
            overlayPlacementDiagnostics = overlayPanelController.show(
                model: appModel,
                preferredScreenID: preferredOverlayScreenID
            )
        }

        afterStateChange?()
        onPlacementResolved?()
    }

    func notchPop() {
        guard notchStatus == .closed, !showOnlyForNotifications else { return }
        islandSurface = .sessionList()
        notchStatus = .popping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.notchStatus == .popping else { return }
            self.notchStatus = .closed
            self.updateClosedOverlayVisibility()
        }
    }

    func performBootAnimation() {
        guard !showOnlyForNotifications else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.notchOpen(reason: .boot, surface: .sessionList())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.notchOpenReason == .boot else { return }
                self?.notchClose()
            }
        }
    }

    func ensureOverlayPanel() {
        guard let appModel else { return }
        overlayPlacementDiagnostics = overlayPanelController.ensurePanel(
            model: appModel,
            preferredScreenID: preferredOverlayScreenID,
            visuallyVisible: notchStatus != .closed || !showOnlyForNotifications,
            interactive: notchStatus == .opened
        )
    }

    // Legacy compatibility
    func showOverlay() { notchOpen(reason: .click, surface: .sessionList()) }
    func hideOverlay() { notchClose() }

    /// Transition from notification mode (single session) to full session list.
    /// - Parameter clearExpansion: If true, clears the actionable session's expansion
    ///   (used for completion notifications which are informational only).
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        if clearExpansion {
            islandSurface = .sessionList()
        }
        // When not clearing, keep actionableSessionID so approval/question expansion persists
        notchOpenReason = .click
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        refreshOverlayPlacementIfVisible()
    }

    // MARK: - Display configuration

    func refreshOverlayDisplayConfiguration() {
        overlayDisplayOptions = overlayPanelController.availableDisplayOptions()

        let validSelectionIDs = Set(overlayDisplayOptions.map(\.id))
        if !validSelectionIDs.contains(overlayDisplaySelectionID) {
            overlayDisplaySelectionID = OverlayDisplayOption.automaticID
            return
        }

        refreshOverlayPlacement()
    }

    func refreshOverlayPlacement() {
        overlayPlacementDiagnostics = overlayPanelController.reposition(
            preferredScreenID: preferredOverlayScreenID
        )
    }

    func refreshOverlayPlacementIfVisible() {
        refreshOverlayPlacement()
    }

    private func reassertOverlayOnActiveSpace() {
        guard let appModel else { return }
        overlayPlacementDiagnostics = overlayPanelController.ensurePanel(
            model: appModel,
            preferredScreenID: preferredOverlayScreenID,
            visuallyVisible: notchStatus != .closed || !showOnlyForNotifications,
            interactive: notchStatus == .opened
        )
    }

    // MARK: - Pointer tracking

    var shouldAutoCollapseOnMouseLeave: Bool {
        if ignoresPointerExitDuringHarness {
            return false
        }

        guard notchStatus == .opened else {
            return false
        }

        if notchOpenReason == .notification {
            return islandSurface.autoDismissesWhenPresentedAsNotification(
                session: activeIslandCardSession
            )
        }

        if islandSurface.isNotificationCard,
           !islandSurface.autoDismissesWhenPresentedAsNotification(
               session: activeIslandCardSession
           ) {
            return false
        }

        if showOnlyForNotifications {
            return true
        }

        return notchOpenReason == .hover && !islandSurface.isNotificationCard
    }

    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool {
        guard notchOpenReason == .notification else { return false }
        // If the session was removed from state (e.g. by process monitoring),
        // default to requiring prior surface entry — prevents the notification
        // from closing immediately on pointer exit before the user sees it.
        guard let session = activeIslandCardSession else { return true }
        return islandSurface.autoDismissesWhenPresentedAsNotification(session: session)
    }

    var showsNotificationCard: Bool {
        islandSurface.isNotificationCard
    }

    func notePointerInsideIslandSurface() {
        cancelPointerExitAutoHide()

        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = true
        autoCollapseSurfaceHasBeenEntered = true

        if notchOpenReason == .notification {
            notificationAutoCollapseTask?.cancel()
            notificationAutoCollapseTask = nil
        }
    }

    func handlePointerExitedIslandSurface() {
        guard shouldTrackPointerInsideIslandSurface else {
            return
        }

        isPointerInsideIslandSurface = false

        guard shouldAutoCollapseOnMouseLeave else {
            return
        }

        guard !autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry
                || autoCollapseSurfaceHasBeenEntered else {
            return
        }

        if showOnlyForNotifications {
            schedulePointerExitAutoHide()
        } else {
            notchClose()
        }
    }

    // MARK: - Notification surfaces

    func presentNotificationSurface(_ surface: IslandSurface) {
        guard surface.isNotificationCard else {
            return
        }

        cancelPointerExitAutoHide()

        guard !shouldPreserveCurrentNotificationSurface(against: surface) else {
            return
        }

        appModel?.measuredNotificationContentHeight = 0
        NotificationSoundService.playNotification(isMuted: isSoundMuted)
        notchOpen(reason: .notification, surface: surface)
    }

    func shouldPreserveCurrentNotificationSurface(against candidate: IslandSurface) -> Bool {
        guard candidate.isNotificationCard,
              notchStatus == .opened,
              notchOpenReason == .notification,
              islandSurface.isNotificationCard,
              islandSurface != candidate else {
            return false
        }

        return isPointerInsideCurrentNotificationCard
    }

    func reconcileIslandSurfaceAfterStateChange() {
        guard islandSurface.isNotificationCard else {
            return
        }

        let session = activeIslandCardSession
        guard islandSurface.matchesCurrentState(of: session) else {
            if notchOpenReason == .notification {
                notchClose()
            } else {
                islandSurface = .sessionList()
            }
            return
        }

        updateNotificationAutoCollapse()
    }

    func dismissNotificationSurfaceIfPresent(for sessionID: String) {
        guard islandSurface.sessionID == sessionID,
              notchOpenReason == .notification else {
            return
        }

        notchClose()
    }

    func dismissOverlayForJump() {
        guard isOverlayVisible else {
            return
        }

        notchClose()
    }

    private func updateNotificationAutoCollapse() {
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil

        guard notchStatus == .opened,
              notchOpenReason == .notification,
              islandSurface.autoDismissesWhenPresentedAsNotification(session: activeIslandCardSession) else {
            return
        }

        if overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation) {
            notePointerInsideIslandSurface()
            return
        }

        notificationAutoCollapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.notificationSurfaceAutoCollapseDelay))
            } catch {
                // Task was cancelled (e.g. a new event reset the timer).
                // Do NOT proceed — the replacement task owns the new timer.
                return
            }

            guard let self,
                  self.notchStatus == .opened,
                  self.notchOpenReason == .notification,
                  self.islandSurface.autoDismissesWhenPresentedAsNotification(session: self.activeIslandCardSession) else {
                return
            }

            guard !self.shouldDeferTimedNotificationAutoCollapse else {
                return
            }

            self.notchClose()
        }
    }

    private func schedulePointerExitAutoHide() {
        guard pointerExitAutoHideTask == nil else {
            return
        }

        pointerExitAutoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(Self.pointerExitAutoHideDelay)
                )
            } catch {
                return
            }

            guard let self else {
                return
            }

            self.pointerExitAutoHideTask = nil
            guard self.showOnlyForNotifications,
                  self.shouldAutoCollapseOnMouseLeave,
                  !self.isPointerInsideIslandSurface else {
                return
            }

            self.notchClose()
        }
    }

    private func cancelPointerExitAutoHide() {
        pointerExitAutoHideTask?.cancel()
        pointerExitAutoHideTask = nil
    }

    var shouldDeferTimedNotificationAutoCollapse: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation)
    }

    private var shouldTrackPointerInsideIslandSurface: Bool {
        shouldAutoCollapseOnMouseLeave
            || (notchStatus == .opened && notchOpenReason == .notification && islandSurface.isNotificationCard)
    }

    private var isPointerInsideCurrentNotificationCard: Bool {
        isPointerInsideIslandSurface
            || overlayPanelController.isPointInExpandedArea(NSEvent.mouseLocation)
    }

    // MARK: - Debug snapshots (overlay portion)

    func exerciseHiddenOverlayHoverForHarness() {
        overlayPanelController.exerciseHiddenOverlayHoverForHarness()
    }

    func exercisePointerExitAutoHideForHarness() {
        notePointerInsideIslandSurface()
        handlePointerExitedIslandSurface()
    }

    func exercisePointerReentryForHarness() {
        notePointerInsideIslandSurface()
    }

    func applyOverlayState(from snapshot: IslandDebugSnapshot, presentOverlay: Bool, autoCollapseNotificationCards: Bool) {
        cancelPointerExitAutoHide()
        notificationAutoCollapseTask?.cancel()
        notificationAutoCollapseTask = nil
        autoCollapseSurfaceHasBeenEntered = false
        isPointerInsideIslandSurface = false

        islandSurface = snapshot.islandSurface
        notchStatus = snapshot.notchStatus
        notchOpenReason = snapshot.notchOpenReason

        if autoCollapseNotificationCards {
            updateNotificationAutoCollapse()
        }

        guard presentOverlay, let appModel else {
            return
        }

        // Immediate interactivity update.
        let interactive = snapshot.notchStatus == .opened
        overlayPanelController.setInteractive(interactive)

        // Defer AppKit panel animation to the next run-loop iteration.
        overlayTransitionGeneration &+= 1
        let capturedGeneration = overlayTransitionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlayTransitionGeneration == capturedGeneration else { return }
            switch snapshot.notchStatus {
            case .opened:
                self.overlayPlacementDiagnostics = self.overlayPanelController.show(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID
                )
            case .closed, .popping:
                self.overlayPanelController.ensurePanel(
                    model: appModel,
                    preferredScreenID: self.preferredOverlayScreenID,
                    visuallyVisible: snapshot.notchStatus != .closed || !self.showOnlyForNotifications,
                    interactive: false
                )
                self.refreshOverlayPlacement()
            }
            self.harnessRuntimeMonitor?.recordMilestone("overlayPresented", message: snapshot.title)
        }
    }

    // MARK: - Persistence

    private func updateClosedOverlayVisibility() {
        guard notchStatus == .closed else { return }

        if showOnlyForNotifications {
            overlayPanelController.hideCompletely()
            return
        }

        guard let appModel else { return }
        overlayPanelController.ensurePanel(
            model: appModel,
            preferredScreenID: preferredOverlayScreenID,
            visuallyVisible: true,
            interactive: false
        )
    }

    private func persistOverlayDisplayPreference() {
        let defaults = UserDefaults.standard
        if overlayDisplaySelectionID == OverlayDisplayOption.automaticID {
            defaults.removeObject(forKey: "overlay.display.preference")
        } else {
            defaults.set(overlayDisplaySelectionID, forKey: "overlay.display.preference")
        }
    }
}
