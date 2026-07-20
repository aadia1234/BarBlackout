import AppKit

// MARK: - Settings menu container

/// AppKit-native container for the hide-mode rows. Used inside the menubar
/// dropdown to avoid the SwiftUI/NSHostingView/NSMenu re-layout cascade that
/// caused per-hover lag once a mode was selected.
final class SettingsMenuView: NSView {
    private let rows: [HideModeRowView]
    private static let rowHeight: CGFloat = 45

    init(width: CGFloat) {
        let configs: [(icon: String, title: String, mode: HideMode)] = [
            ("eye.slash.fill",                     "Hide Menu Bar",        .always),
            ("rectangle.split.2x1.fill",           "On Desktop Only",      .desktopOnly),
            ("arrow.up.left.and.arrow.down.right", "On Full-Screen Only",  .fullScreenOnly),
        ]
        let rowH = Self.rowHeight
        let built = configs.map {
            HideModeRowView(icon: $0.icon, title: $0.title, mode: $0.mode, width: width, height: rowH)
        }
        self.rows = built
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH * CGFloat(configs.count)))

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for (i, row) in built.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: CGFloat(configs.count - 1 - i) * rowH,
                width: width,
                height: rowH
            )
            addSubview(row)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    func refresh() { rows.forEach { $0.refresh() } }
}

// MARK: - Single mode row

final class HideModeRowView: NSView {
    private let mode: HideMode
    private let circle = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(icon: String, title: String, mode: HideMode, width: CGFloat, height: CGFloat) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true

        let circleSize: CGFloat = 30
        circle.wantsLayer = true
        circle.layer?.cornerRadius = circleSize / 2
        circle.frame = NSRect(
            x: 14,
            y: (height - circleSize) / 2,
            width: circleSize,
            height: circleSize
        )
        addSubview(circle)

        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        iconView.frame = circle.bounds
        circle.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.stringValue = title
        let labelX = 14 + circleSize + 14
        titleLabel.frame = NSRect(
            x: labelX,
            y: (height - 18) / 2,
            width: width - labelX - 14,
            height: 18
        )
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        MenuBarManager.shared.setHideMode(mode)
        (superview as? SettingsMenuView)?.refresh()
    }

    func refresh() {
        let active = MenuBarManager.shared.hideMode == mode
        circle.layer?.backgroundColor = (active ? NSColor.controlAccentColor : NSColor.controlColor).cgColor
        iconView.contentTintColor = active ? .white : .labelColor
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = hovering
            ? NSColor.gray.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }
}
