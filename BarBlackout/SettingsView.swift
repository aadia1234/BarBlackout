import SwiftUI

/// Encapsulates the full Settings section — a vertical stack of
/// `SettingsButtonView` rows for the contextual hide modes.
struct SettingsView: View {
    let width: CGFloat

    private static let rows: [(icon: String, title: String, mode: HideMode)] = [
        ("rectangle.split.2x1.fill",           "On Desktop Only",     .desktopOnly),
        ("arrow.up.left.and.arrow.down.right", "On Full-Screen Only", .fullScreenOnly),
        ("play.rectangle.fill",                "On Video Playback Only", .videoOnly),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows, id: \.mode) { row in
                SettingsButtonView(icon: row.icon, title: row.title, mode: row.mode, width: width)
            }
        }
        .frame(width: width)
    }
}

/// One row in the Settings disclosure section. AppDelegate / `SettingsView`
/// builds these — one per `HideMode`.
struct SettingsButtonView: View {
    @EnvironmentObject private var manager: MenuBarManager
    let icon: String
    let title: String
    let mode: HideMode
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let active = manager.hideMode == mode
        Button { manager.setHideMode(mode) } label: {
            HStack(spacing: 7.5) {
                ZStack {
                    Circle()
                        .fill(active ? Color.accentColor : Color(NSColor.controlColor))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(active ? .white : .primary)
                }
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(Color.gray.opacity(hovering ? 0.18 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(width: width)
    }
}

/// Top-level "Menu Bar" toggle that sits above the disclosure sections.
struct MenuBarToggleView: View {
    @EnvironmentObject private var manager: MenuBarManager
    let width: CGFloat

    var body: some View {
        HStack {
            Text("Menu Bar")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            NativeSwitch(isOn: Binding(
                get: { manager.hideMode == .always },
                set: { _ in manager.setHideMode(.always) }
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: width)
    }
}

/// SwiftUI wrapper around `AccentSwitch` — a native NSSwitch with an
/// accent-colored overlay drawn over the track when on. Necessary because
/// NSMenu's tracking window reports as inactive, so NSSwitch's default
/// "on" tint renders gray instead of the system accent.
private struct NativeSwitch: NSViewRepresentable {
    @Binding var isOn: Bool

    func makeNSView(context: Context) -> AccentSwitch {
        let sw = AccentSwitch()
        sw.target = context.coordinator
        sw.action = #selector(Coordinator.changed(_:))
        return sw
    }

    func updateNSView(_ nsView: AccentSwitch, context: Context) {
        nsView.state = isOn ? .on : .off
        nsView.refreshAccentOverlay()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: NativeSwitch
        init(_ parent: NativeSwitch) { self.parent = parent }
        @objc func changed(_ sender: AccentSwitch) {
            parent.isOn = sender.state == .on
            sender.refreshAccentOverlay()
        }
    }
}

/// `NSSwitch` subclass that paints an accent-colored capsule over the
/// track when `state == .on`. The native knob (and its animation) show
/// through a knob-shaped hole cut into the overlay.
final class AccentSwitch: NSSwitch {
    private let accentOverlay = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        accentOverlay.fillRule = .evenOdd
        accentOverlay.fillColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(accentOverlay)
        refreshAccentOverlay()
    }

    override func layout() {
        super.layout()
        refreshAccentOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        refreshAccentOverlay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        accentOverlay.fillColor = NSColor.controlAccentColor.cgColor
    }

    func refreshAccentOverlay() {
        guard state == .on else {
            accentOverlay.isHidden = true
            return
        }
        accentOverlay.isHidden = false
        accentOverlay.frame = bounds

        let radius = bounds.height / 2
        accentOverlay.path = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }
}
#Preview {
    SettingsView(width: 310)
        .environmentObject(MenuBarManager.preview)
}

