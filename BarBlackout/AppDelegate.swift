import Cocoa
import SwiftUI
import Combine

// MARK: - Menu item container

/// Wraps any SwiftUI view inside an NSMenuItem.
/// `acceptsFirstMouse` → true so Toggle/Button fire on the very first click.
final class MenuItemContainerView: NSView {
    private let hosting: NSHostingView<AnyView>

    init<V: View>(_ content: V, width: CGFloat? = nil) {
        hosting = NSHostingView(rootView: AnyView(content))
        let w = width ?? hosting.fittingSize.width
        // Measure height at the width we're actually going to use. Reading
        // fittingSize before applying the width reports the height for the
        // natural (narrow) layout, which leaves dead space below content whose
        // height depends on width — it showed up as a gray strip under the
        // slider row.
        hosting.setFrameSize(NSSize(width: w, height: 0))
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height

        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        hosting.frame = bounds
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var allowsVibrancy: Bool { false }
}

// MARK: - Status item art

/// Draws the BarBlackout mark: a ring that fills from its right edge as a hide
/// timer runs down. `progress` 0 → bare ring (blacked out), 1 → solid disc
/// (menu bar visible).
///
/// The filled region is the right semicircle closed off by a terminator ellipse
/// of x-radius r·|1−2p|, which bulges right below the midpoint (cutting area
/// away) and left above it (adding area). That yields a filled area of exactly
/// p·πr², so the mark reads as a linear progress gauge.
///
/// Built as one continuous subpath on purpose: composing it from two subpaths
/// would make the result depend on winding-rule interactions, which is where
/// the SVG drafts of this same shape went wrong twice.
enum StatusIcon {
    private static let canvas: CGFloat = 18
    private static let center = NSPoint(x: 9, y: 9)
    private static let ringR:  CGFloat = 6.4
    private static let ringW:  CGFloat = 1.6
    /// Full state grows past the ring so it reads as a solid disc, not a
    /// filled-in outline.
    private static let fullR:  CGFloat = 7.2
    /// Circle-to-bezier constant, for the quarter-ellipse terminator curves.
    private static let kappa:  CGFloat = 0.5522847498

    static func image(progress p: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: canvas, height: canvas),
                          flipped: false) { _ in
            NSColor.black.set()

            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringR,
                                                   y: center.y - ringR,
                                                   width: ringR * 2,
                                                   height: ringR * 2))
            ring.lineWidth = ringW
            ring.stroke()

            if p >= 0.995 {
                NSBezierPath(ovalIn: NSRect(x: center.x - fullR,
                                            y: center.y - fullR,
                                            width: fullR * 2,
                                            height: fullR * 2)).fill()
            } else if p > 0.005 {
                fillPath(for: CGFloat(p)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "BarBlackout"
        return img
    }

    private static func fillPath(for p: CGFloat) -> NSBezierPath {
        let r   = ringR
        let top = NSPoint(x: center.x, y: center.y + r)
        // Signed x-radius of the terminator: positive bulges right, negative left.
        let sx  = (p < 0.5 ? 1 : -1) * abs(r * (1 - 2 * p))

        let path = NSBezierPath()
        // Top -> bottom, the long way round the right edge.
        path.appendArc(withCenter: center, radius: r,
                       startAngle: 90, endAngle: -90, clockwise: true)
        // Bottom -> waist -> top, along the terminator.
        path.curve(to: NSPoint(x: center.x + sx, y: center.y),
                   controlPoint1: NSPoint(x: center.x + sx * kappa, y: center.y - r),
                   controlPoint2: NSPoint(x: center.x + sx, y: center.y - r * kappa))
        path.curve(to: top,
                   controlPoint1: NSPoint(x: center.x + sx, y: center.y + r * kappa),
                   controlPoint2: NSPoint(x: center.x + sx * kappa, y: center.y + r))
        path.close()
        return path
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    /// Slider row below the duration circles, revealed by the gear button.
    /// It only shows when the Duration section is expanded AND the gear is on.
    private var sliderItem: NSMenuItem?
    private var durationExpanded = false
    private var customSub: AnyCancellable?
    /// Mirrors MenuBarManager.customMinutes != nil. Kept as a stored copy
    /// because @Published publishes in willSet — reading the property back
    /// inside the sink would give the previous value.
    private var customOn = false

    /// Redraw ticker for the status icon. Runs only while a hide with an
    /// expiry is counting down — there's nothing to animate otherwise.
    private var iconTimer: Timer?
    private var iconSubs = Set<AnyCancellable>()
    /// Last drawn fill, quantised to 1/60 of the disc. Finer steps aren't
    /// visible at 18pt, so skipping them avoids pointless NSImage churn on a
    /// four-hour hide.
    private var lastDrawnPhase = -1

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] != "1" else { return }
        MenuBarManager.shared.restoreState()
        setupMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconTimer?.invalidate()
        iconTimer = nil
        MenuBarManager.shared.cleanup()
    }

    // MARK: Status icon

    private func startWatchingProgress() {
        let mgr = MenuBarManager.shared
        mgr.$hideMode.map { _ in () }
            .merge(with: mgr.$offDate.map { _ in () })
            .sink { [weak self] in
                // @Published publishes in willSet, so the manager still holds
                // the old value here — let the change land before reading it.
                DispatchQueue.main.async { self?.syncIconTicker() }
            }
            .store(in: &iconSubs)

        syncIconTicker()
    }

    /// Starts or stops the ticker to match whether a countdown is running, then
    /// redraws once so the icon is right even when nothing is ticking.
    private func syncIconTicker() {
        let mgr = MenuBarManager.shared
        let counting = mgr.hideMode != .off && mgr.offDate != nil

        if counting, iconTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshStatusIcon()
            }
            RunLoop.main.add(t, forMode: .common)
            iconTimer = t
        } else if !counting {
            iconTimer?.invalidate()
            iconTimer = nil
        }

        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let btn = statusItem?.button else { return }

        let p = MenuBarManager.shared.restoreProgress
        let phase = Int((p * 60).rounded())
        guard phase != lastDrawnPhase else { return }
        lastDrawnPhase = phase

        btn.image = StatusIcon.image(progress: p)
    }

    // MARK: Setup

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // No button means no status item to draw into — nothing else to set up.
        guard statusItem.button != nil else { return }
        startWatchingProgress()

        let mgr = MenuBarManager.shared

        // About item
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        aboutItem.target = self
        quitItem.target = self
        
        menu = NSMenu()
        menu.autoenablesItems = false

        // Pre-measure so the menu opens at a fixed width regardless of which
        // sections are expanded.
        let durationContent = MenuItemContainerView(
            DurationView(onGearTap: { [weak self] in self?.toggleSliderRow() })
                .environmentObject(mgr)
        )
        let fixedWidth = max(durationContent.frame.width, 310)
        durationContent.setFrameSize(NSSize(width: fixedWidth, height: durationContent.frame.height))

        let settingsContent = MenuItemContainerView(
            SettingsView(width: fixedWidth).environmentObject(mgr)
        )

        // ── Menu Bar toggle (top-level) ───────────────────────────
        let toggleItem = NSMenuItem()
        toggleItem.view = MenuItemContainerView(
            MenuBarToggleView(width: fixedWidth).environmentObject(mgr)
        )
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        // ── Duration ──────────────────────────────────────────────
        // Built by hand rather than via addDisclosureSection: the slider row
        // has its own visibility state on top of the section's expansion.
        let durationItem = NSMenuItem()
        durationItem.view = durationContent
        durationItem.isHidden = true

        let sliderRow = NSMenuItem()
        sliderRow.view = MenuItemContainerView(
            CustomDurationView(width: fixedWidth).environmentObject(mgr),
            width: fixedWidth
        )
        sliderRow.isHidden = true
        sliderItem = sliderRow

        // Slider visibility tracks custom mode: picking a preset (which clears
        // customMinutes) or switching the app off both hide the row.
        //
        // No receive(on:) — these all mutate on the main thread already, and
        // hopping through a scheduler doesn't reliably deliver while an NSMenu
        // is open, which left the row stale until the menu was reopened.
        customOn = mgr.customActive
        customSub = Publishers.CombineLatest(mgr.$customMinutes, mgr.$hideMode)
            .sink { [weak self] minutes, mode in
                guard let self else { return }
                self.customOn = (minutes != nil && mode != .off)
                self.updateSliderVisibility()
            }

        let durationHeader = NSMenuItem()
        durationHeader.view = DisclosureHeaderView(
            title: "Duration",
            targets: [durationItem],
            width: fixedWidth,
            showsOffTime: true
        ) { [weak self] expanded in
            guard let self else { return }
            self.durationExpanded = expanded
            self.updateSliderVisibility()
        }

        menu.addItem(durationHeader)
        menu.addItem(durationItem)
        menu.addItem(sliderRow)

        // ── Settings ──────────────────────────────────────────────
        addDisclosureSection(title: "Settings", contents: [settingsContent], width: fixedWidth)

        // ── Actions ───────────────────────────────────────────────
        menu.addItem(.separator())
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func toggleSliderRow() {
        let mgr = MenuBarManager.shared
        // Already the active duration — leave it alone rather than dropping
        // back to a preset. Visibility follows from the subscription.
        guard !mgr.customActive else { return }
        mgr.enableCustom()
    }

    /// The slider shows exactly when custom mode is on — and, since it lives
    /// inside the Duration section, only while that section is expanded.
    private func updateSliderVisibility() {
        sliderItem?.isHidden = !(durationExpanded && customOn)
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }

    /// Appends a disclosure header followed by N (initially hidden) content
    /// items. Clicking the header expands/collapses all content rows inline.
    private func addDisclosureSection(title: String, contents: [NSView], width: CGFloat) {
        let contentItems: [NSMenuItem] = contents.map { view in
            let item = NSMenuItem()
            item.view = view
            item.isHidden = true
            return item
        }

        let headerItem = NSMenuItem()
        headerItem.view = DisclosureHeaderView(title: title, targets: contentItems, width: width)

        menu.addItem(headerItem)
        contentItems.forEach { menu.addItem($0) }
    }
}

// MARK: - Disclosure header

/// Clickable header row that toggles the visibility of an associated
/// content menu item without dismissing the enclosing menu.
final class DisclosureHeaderView: NSView {
    private let targets: [NSMenuItem]
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var expanded = false
    /// Notified on every toggle, for rows whose visibility depends on more
    /// than just this section being open.
    private let onToggle: ((Bool) -> Void)?
    private var offDateSub: AnyCancellable?
    private let baseTitle: String

    private static let offTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    init(title: String, targets: [NSMenuItem], width: CGFloat,
         showsOffTime: Bool = false,
         onToggle: ((Bool) -> Void)? = nil) {
        self.targets = targets
        self.onToggle = onToggle
        self.baseTitle = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chevron)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])

        if showsOffTime {
            // Delivered synchronously on purpose: offDate is only ever set on
            // the main thread, and scheduler hops don't reliably run while an
            // NSMenu holds the event loop — that's why the time used to appear
            // only after reopening the menu.
            offDateSub = MenuBarManager.shared.$offDate
                .sink { [weak self] date in self?.updateTitle(offDate: date) }
        }
    }

    /// "Duration" plus a gray off-time. One attributed label rather than two
    /// views, so it re-lays out reliably inside a menu item.
    private func updateTitle(offDate: Date?) {
        let s = NSMutableAttributedString(
            string: baseTitle,
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: NSColor.labelColor]
        )
        if let d = offDate {
            s.append(NSAttributedString(
                string: "  " + Self.offTimeFormatter.string(from: d),
                attributes: [.font: NSFont.menuFont(ofSize: 0),
                             .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        titleLabel.attributedStringValue = s
        titleLabel.sizeToFit()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var allowsVibrancy: Bool { false }

    override func mouseDown(with event: NSEvent) {
        expanded.toggle()
        targets.forEach { $0.isHidden = !expanded }
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        onToggle?(expanded)
    }
}

// MARK: - NSMenu convenience

private extension NSMenu {
    /// Wraps a SwiftUI view in a MenuItemContainerView and appends it.
    func addItem<V: View>(containing view: V) {
        let container = MenuItemContainerView(view)
        let item = NSMenuItem()
        item.view = container
        addItem(item)
    }
}
