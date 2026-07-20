 import AppKit

/// A solid-black borderless window that sits one level above the menu bar,
/// visually hiding it without touching any system setting.
///
/// Hover-to-reveal: when the cursor enters the menu-bar zone the overlay
/// steps aside so the user can see and interact with the real menu bar
/// (including the app's own status item), then re-covers it on mouse-out.
final class MenuBarOverlay {

    static let shared = MenuBarOverlay()

    /// True while the overlay should be drawn (mode is active for this space).
    private(set) var isActive = false

    private var overlayWindow: NSWindow?
    private var mouseMonitor: Any?
    /// Backstop for the event monitor — see startHoverTracking.
    private var hoverTimer: Timer?
    /// True while the cursor is in the menu-bar zone and the overlay is hidden.
    private var revealedByHover = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Public
    // Must be called on the main thread.

    func activate() {
        isActive = true
        makeWindowIfNeeded()
        updateVisibility()
        startHoverTracking()
    }

    func deactivate() {
        isActive = false
        revealedByHover = false
        updateVisibility()
        stopHoverTracking()
    }

    // MARK: - Window

    private func makeWindowIfNeeded() {
        guard overlayWindow == nil else { return }

        let w = NSWindow(
            contentRect: menuBarFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        // One level above the status bar — sits on top of all menu-bar items.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Click-through: real menu-bar items below are still hittable.
        w.ignoresMouseEvents = true
        // Stay on every Space and slide into full-screen spaces too.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        overlayWindow = w
    }

    /// Height the system is currently reserving for the menu bar on the main
    /// screen, in points.
    ///
    /// screen.frame.maxY        = top of physical display
    /// screen.visibleFrame.maxY = bottom edge of the menu bar
    ///
    /// The difference is the exact reserved height — covers the notch on
    /// MacBook Pro without any hardcoded values.
    ///
    /// NOTE: this does NOT collapse to 0 in a full-screen Space, despite what
    /// an earlier version of this comment claimed. Measured on macOS 26 it
    /// keeps reporting the desktop value, which is why full-screen detection
    /// lives in MenuBarManager.isFullScreenSpaceActive() and uses the Space
    /// type instead. Use this only for sizing, never for detection.
    static var currentMenuBarHeight: CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    /// Last non-zero menu-bar height we observed. In a full-screen Space the
    /// live reserve collapses to 0, but the strip we want to cover is still
    /// there (the menu bar drops down on hover), so fall back to this.
    private static var lastKnownMenuBarHeight: CGFloat = 24

    /// Height to actually draw — live reserve when there is one, otherwise the
    /// last real value we saw.
    private var drawHeight: CGFloat {
        let live = Self.currentMenuBarHeight
        if live > 0.5 {
            Self.lastKnownMenuBarHeight = live
            return live
        }
        return Self.lastKnownMenuBarHeight
    }

    private var menuBarFrame: NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let h = drawHeight
        // Anchor to the physical top of the display, not visibleFrame.maxY —
        // in full screen those differ and visibleFrame would place us wrong.
        return NSRect(x: screen.frame.minX,
                      y: screen.frame.maxY - h,
                      width: screen.frame.width,
                      height: h)
    }

    private func updateVisibility() {
        // Always called on main thread (callers guarantee this).
        guard let w = overlayWindow else { return }
        if isActive && !revealedByHover {
            let f = menuBarFrame
            if w.frame != f { w.setFrame(f, display: false) }
            // Re-ordering an already-visible window every poll tick causes
            // visible flicker, so only order when it isn't up yet.
            if !w.isVisible { w.orderFrontRegardless() }
        } else if w.isVisible {
            w.orderOut(nil)
        }
    }

    @objc private func screensChanged() {
        guard isActive else { return }
        DispatchQueue.main.async { [self] in
            overlayWindow?.setFrame(menuBarFrame, display: true)
        }
    }

    // MARK: - Hover tracking

    private func startHoverTracking() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.evaluateHover()
            }
        }
        // The event monitor alone is not enough: it goes quiet while another
        // app tracks the mouse, during drags, and in full-screen Spaces, which
        // could leave the bar black with the cursor sitting in it. Polling the
        // cursor position guarantees the menu bar always reveals on hover.
        if hoverTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.evaluateHover()
            }
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        }
    }

    private func stopHoverTracking() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func evaluateHover() {
        guard isActive else { return }
        guard NSScreen.main != nil else { return }
        // Reveal when the cursor enters the overlay zone — threshold is the
        // bottom edge of the strip we're actually drawing, so this stays
        // correct in a full-screen Space too.
        let inZone = NSEvent.mouseLocation.y >= menuBarFrame.minY
        guard inZone != revealedByHover else { return }
        revealedByHover = inZone
        updateVisibility()
    }
}
