import AppKit

// MARK: - Private window-server API
//
// Space type is the only reliable full-screen signal we found (see
// isFullScreenSpaceActive). These symbols are private SkyLight/CoreGraphics
// entry points, resolved at runtime so a missing symbol degrades to "not full
// screen" instead of failing to launch. Note: private API — not App Store safe.

private typealias CGSConnection = UInt32

private let CGSMainConnectionID: @convention(c) () -> CGSConnection = unsafeBitCast(
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
    to: (@convention(c) () -> CGSConnection).self)

private let CGSCopyManagedDisplaySpaces: @convention(c) (CGSConnection) -> CFArray =
    unsafeBitCast(
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopyManagedDisplaySpaces"),
        to: (@convention(c) (CGSConnection) -> CFArray).self)

// MARK: - Enums

enum HideMode: String {
    case off
    case always               // overlay always — regardless of context
    case desktopOnly          // overlay on desktop (not in full-screen)
    case fullScreenOnly       // overlay in full-screen (not on desktop)
    case videoOnly            // overlay only in full-screen AND while video plays
}

enum HideDuration: String, CaseIterable, Equatable {
    case forever = "forever"
    case min15   = "15m"
    case min30   = "30m"
    case min45   = "45m"
    case hour1   = "1h"
    case hour2   = "2h"
    case hour4   = "4h"

    var label: String {
        switch self {
        case .forever: return "∞"
        case .min15:   return "15"
        case .min30:   return "30"
        case .min45:   return "45"
        case .hour1:   return "01"
        case .hour2:   return "02"
        case .hour4:   return "04"
        }
    }

    var menuTitle: String {
        switch self {
        case .forever: return "Forever"
        case .min15:   return "15 Minutes"
        case .min30:   return "30 Minutes"
        case .min45:   return "45 Minutes"
        case .hour1:   return "1 Hour"
        case .hour2:   return "2 Hours"
        case .hour4:   return "4 Hours"
        }
    }

    /// nil = no expiry (forever)
    var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .min15:   return 15 * 60
        case .min30:   return 30 * 60
        case .min45:   return 45 * 60
        case .hour1:   return 1  * 3600
        case .hour2:   return 2  * 3600
        case .hour4:   return 4  * 3600
        }
    }
}

// MARK: - Manager

final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()

    /// Fresh instance with no side effects — safe to use in Xcode previews.
    #if DEBUG
    static var preview: MenuBarManager { MenuBarManager() }
    #endif

    @Published private(set) var hideMode:     HideMode     = .off
    @Published private(set) var hideDuration: HideDuration = .forever

    /// Wall-clock time the overlay will switch itself off, or nil when it's
    /// off already or running with no expiry. Drives the Duration header.
    @Published private(set) var offDate: Date?

    /// Custom duration in minutes, set via the slider. When non-nil it wins
    /// over `hideDuration`; picking a preset button clears it back to nil.
    @Published private(set) var customMinutes: Int? = nil

    /// Mode to resume when the user turns the app back on without picking a
    /// mode — e.g. by tapping a duration while it's off.
    private var lastActiveMode: HideMode = .always

    /// Seconds until auto-off, or nil for no expiry.
    private var effectiveSeconds: TimeInterval? {
        if let m = customMinutes {
            // 0 on the slider means "no expiry", same as ∞.
            return m == 0 ? nil : TimeInterval(m * 60)
        }
        return hideDuration.seconds
    }

    /// How close the menu bar is to coming back: 0 the moment a blackout
    /// starts, 1 once it's visible again. Drives the status item's fill.
    ///
    /// Deliberately tracks the *timer*, not whether the overlay happens to be
    /// up this instant — the context-gated modes (.desktopOnly, .videoOnly)
    /// raise and drop the overlay repeatedly within a single hide, and the icon
    /// would strobe if it followed them.
    var restoreProgress: Double {
        guard hideMode != .off else { return 1 }
        // No expiry (forever, or the slider at 0): nothing is scheduled to
        // bring the bar back, so the mark stays empty.
        guard let off = offDate, let total = effectiveSeconds, total > 0 else { return 0 }
        let remaining = off.timeIntervalSinceNow
        return min(max(1 - remaining / total, 0), 1)
    }

    private var durationTimer: Timer?
    /// Safety net: notifications for entering/leaving full screen are not
    /// fully reliable, so re-evaluate periodically while a mode is active.
    private var contextTimer: Timer?

    /// Sole consumer, no shared state — a stored property rather than a
    /// singleton keeps MenuBarManager.preview side-effect-free.
    private let videoDetector = VideoDetector()

    /// Last moment video was seen playing, for the .videoOnly grace period.
    private var lastVideoPlayingAt: Date?
    private static let videoDropGrace: TimeInterval = 3.0
    /// Registered on NSWorkspace.shared.notificationCenter.
    private var workspaceObservers: [Any] = []
    /// Registered on NotificationCenter.default — a *different* center, so
    /// these must be removed from the right one.
    private var defaultCenterObservers: [Any] = []

    private init() {}

    // MARK: Lifecycle

    func restoreState() {
        let savedMode = HideMode(
            rawValue: UserDefaults.standard.string(forKey: "mbapp.hideMode") ?? "off"
        ) ?? .off
        let savedDuration = HideDuration(
            rawValue: UserDefaults.standard.string(forKey: "mbapp.hideDuration") ?? "forever"
        ) ?? .forever

        hideMode     = savedMode
        hideDuration = savedDuration
        if UserDefaults.standard.object(forKey: "mbapp.customMinutes") != nil {
            customMinutes = UserDefaults.standard.integer(forKey: "mbapp.customMinutes")
        }
        lastActiveMode = HideMode(
            rawValue: UserDefaults.standard.string(forKey: "mbapp.lastMode") ?? "always"
        ) ?? .always

        setupObservers()

        if savedMode != .off {
            // Give the system a moment to settle before showing the overlay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.applyOverlayForCurrentContext()
            }
            startDurationTimer()
            startContextPolling()
        }
    }

    func cleanup() {
        stopAllTimers()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        defaultCenterObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultCenterObservers.removeAll()
        MenuBarOverlay.shared.deactivate()
    }

    // MARK: Public controls

    func setHideMode(_ mode: HideMode) {
        // Tapping the active mode turns it off
        if mode == hideMode, mode != .off {
            deactivate()
            return
        }

        hideMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "mbapp.hideMode")
        if mode != .off {
            lastActiveMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "mbapp.lastMode")
        }
        // Don't inherit a grace window from a previous stint in .videoOnly.
        lastVideoPlayingAt = nil
        stopAllTimers()
        applyOverlayAfterSettling()

        if mode != .off {
            startDurationTimer()
            startContextPolling()
        }
    }

    func setHideDuration(_ duration: HideDuration) {
        hideDuration = duration
        UserDefaults.standard.set(duration.rawValue, forKey: "mbapp.hideDuration")
        // A preset overrides any custom slider value.
        customMinutes = nil
        UserDefaults.standard.removeObject(forKey: "mbapp.customMinutes")
        stopDurationTimer()

        guard hideMode != .off else {
            // Picking a duration while off turns the app on, resuming whatever
            // mode was last active. setHideMode restarts the duration timer.
            setHideMode(lastActiveMode)
            return
        }
        startDurationTimer()
    }

    /// True when custom mode is the duration in force. Drives the gear's
    /// highlight and the slider row's visibility, so they can't disagree —
    /// and, like the preset circles, reads inactive while the app is off.
    var customActive: Bool { customMinutes != nil && hideMode != .off }

    /// Switches to custom mode, restoring the slider's last value. Turns the
    /// app on if it's off, the same as tapping a preset duration.
    ///
    /// There's deliberately no "disable" here: custom mode is left by picking
    /// a preset (which clears customMinutes), so re-tapping the gear while
    /// it's already active is a no-op rather than a silent fallback to some
    /// other duration.
    func enableCustom() {
        customMinutes = UserDefaults.standard.integer(forKey: "mbapp.customMinutesLast")
        UserDefaults.standard.set(customMinutes, forKey: "mbapp.customMinutes")

        guard hideMode != .off else {
            setHideMode(lastActiveMode)
            return
        }
        // Re-arm against whichever duration now applies.
        stopDurationTimer()
        startDurationTimer()
    }

    /// Custom duration from the slider, in 15-minute steps (0...1440).
    /// Like the preset buttons, this turns the app on if it's off.
    func setCustomDuration(minutes: Int) {
        let clamped = min(max(minutes, 0), 24 * 60)
        customMinutes = clamped
        UserDefaults.standard.set(clamped, forKey: "mbapp.customMinutes")
        // Remembered so re-enabling the gear comes back to this value.
        UserDefaults.standard.set(clamped, forKey: "mbapp.customMinutesLast")
        stopDurationTimer()

        guard hideMode != .off else {
            setHideMode(lastActiveMode)
            return
        }
        startDurationTimer()
    }

    // MARK: Overlay logic

    /// Decides whether the overlay should be up right now.
    /// MUST be called on the main thread — NSWindow creation/ordering is not thread-safe.
    private func applyOverlayForCurrentContext() {
        assert(Thread.isMainThread, "applyOverlayForCurrentContext must be called on main thread")

        switch hideMode {
        case .off:
            MenuBarOverlay.shared.deactivate()

        case .always:
            MenuBarOverlay.shared.activate()

        case .desktopOnly:
            if isFullScreenSpaceActive() {
                MenuBarOverlay.shared.deactivate()
            } else {
                MenuBarOverlay.shared.activate()
            }

        case .fullScreenOnly:
            if isFullScreenSpaceActive() {
                MenuBarOverlay.shared.activate()
            } else {
                MenuBarOverlay.shared.deactivate()
            }

        case .videoOnly:
            // Full-screen gate first: it's one window-server call, and it
            // short-circuits the IOKit + CoreAudio work on every tick spent
            // outside full screen. Space type never flickers, so it is
            // deliberately NOT debounced — leaving full screen drops the
            // overlay on the next tick.
            if isFullScreenSpaceActive() && videoIsSustained() {
                MenuBarOverlay.shared.activate()
            } else {
                MenuBarOverlay.shared.deactivate()
            }

        }
    }

    /// Space-change and app-activation notifications fire *before* the screen
    /// metrics finish updating, so sampling the menu-bar reserve right away
    /// still reports the previous Space's value. Apply immediately (keeps the
    /// common case snappy) then re-apply once the transition has settled.
    private func applyOverlayAfterSettling() {
        applyOverlayForCurrentContext()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.applyOverlayForCurrentContext()
        }
    }

    /// True when the active Space is a full-screen Space.
    ///
    /// Measured on this machine (macOS 26): the menu-bar reserve
    /// (frame.maxY - visibleFrame.maxY) stays at its desktop value inside a
    /// full-screen Space, so the reserve can NOT be used to detect full
    /// screen — that was the original bug. Matching a display-sized layer-0
    /// window in CGWindowList doesn't work either; a full-screen app's window
    /// doesn't present that shape.
    ///
    /// The Space type from the window server is authoritative and needs no
    /// Accessibility or Screen Recording permission. type 4 == full-screen.
    private func isFullScreenSpaceActive() -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]]
        else { return false }

        // Prefer the entry for the display we're drawing on; fall back to the
        // first if we can't match (single-display setups always match).
        let mainUUID = MenuBarManager.mainDisplayUUIDString()
        let entry = displays.first {
            ($0["Display Identifier"] as? String) == mainUUID
        } ?? displays.first

        guard let current = entry?["Current Space"] as? [String: Any],
              let type = current["type"] as? Int else { return false }
        return type == 4
    }

    /// True when video is playing, or stopped playing within the last few
    /// seconds.
    ///
    /// Asymmetric on purpose — instant on, delayed off. Display-sleep
    /// assertions are released briefly during ad transitions and seeking, and
    /// without a grace period the real menu bar strobes over the video.
    /// Delaying activation instead would leave the menu bar visible for
    /// seconds after pressing play.
    ///
    /// Time-based rather than tick-counted because this is reached from the 1s
    /// timer, three notification observers, and the 0.35s re-apply — the call
    /// cadence is not uniform.
    private func videoIsSustained() -> Bool {
        if videoDetector.isVideoPlaying() {
            lastVideoPlayingAt = Date()
            return true
        }
        guard let last = lastVideoPlayingAt else { return false }
        return Date().timeIntervalSince(last) < Self.videoDropGrace
    }

    private static func mainDisplayUUIDString() -> String? {
        guard let screen = NSScreen.main,
              let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?
            .takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: Private helpers

    private func deactivate() {
        hideMode = .off
        UserDefaults.standard.set(HideMode.off.rawValue, forKey: "mbapp.hideMode")
        lastVideoPlayingAt = nil
        stopAllTimers()
        MenuBarOverlay.shared.deactivate()
    }

    private func startDurationTimer() {
        guard let secs = effectiveSeconds else { return }
        offDate = Date().addingTimeInterval(secs)
        durationTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.deactivate() }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        offDate = nil
    }

    private func startContextPolling() {
        stopContextPolling()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.applyOverlayForCurrentContext() }
        }
        RunLoop.main.add(t, forMode: .common)
        contextTimer = t
    }

    private func stopContextPolling() {
        contextTimer?.invalidate()
        contextTimer = nil
    }

    private func stopAllTimers() {
        stopDurationTimer()
        stopContextPolling()
    }

    private func setupObservers() {
        // Both observers fire on .main so it's safe to call applyOverlayForCurrentContext.
        let spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyOverlayAfterSettling() }

        let appObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyOverlayAfterSettling() }

        workspaceObservers = [spaceObs, appObs]

        // Entering/leaving full screen doesn't reliably fire either of the
        // above, but it does change the menu-bar reserve — which is exactly
        // what isMenuBarHidden() measures.
        let screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyOverlayForCurrentContext() }

        defaultCenterObservers = [screenObs]
    }

}
