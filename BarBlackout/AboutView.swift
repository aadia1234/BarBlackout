import AppKit
import SwiftUI

// MARK: - Window controller

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let hc  = NSHostingController(rootView: AboutView())

        // Clear the hosting view's own background so the vibrancy shows through.
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = .clear

        let win = NSWindow(contentViewController: hc)
        win.styleMask            = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titleVisibility      = .hidden
        win.titlebarAppearsTransparent = true
        win.isOpaque             = false
        win.backgroundColor      = .clear
        win.isReleasedWhenClosed = false
        win.hasShadow            = true

        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Always re-center on the visible area of the main screen.
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let wf = win.frame
            win.setFrameOrigin(NSPoint(
                x: sf.midX - wf.width  / 2,
                y: sf.midY - wf.height / 2
            ))
        } else {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Vibrancy background

/// NSVisualEffectView wrapper — blurs whatever is behind the window.
private struct VibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = .hudWindow      // dark frosted glass; adapts when system is dark
        v.blendingMode = .behindWindow
        v.state        = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - View

struct AboutView: View {

    // ── Customise these to match your app ────────────────────────────────────
    private let description = "Blackout the bar. It comes back. Hide your menu bar on a timer, and automatically while you watch video."
    private let supportURL  = URL(string: "https://yoursite.com/support")!
    private let websiteURL  = URL(string: "https://github.com/aadia1234/BarBlackout")!
    private let copyright   = "Copyright © 2026 Aadi Anand. All rights reserved."
    // ─────────────────────────────────────────────────────────────────────────

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"]               as? String ?? "BarBlackout"
    }
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            // Frosted-glass fill — extends under the transparent title bar.
            VibrancyBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Main content ─────────────────────────────────────
                HStack(alignment: .center, spacing: 28) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 100, height: 100)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(appName)
                            .font(.system(size: 22, weight: .bold))

                        Text("Version \(version)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.top, 3)

                        Text(description)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)

                        HStack(spacing: 10) {
                            ActionButton("Website") { NSWorkspace.shared.open(websiteURL) }
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 28)

                // ── Footer ───────────────────────────────────────────
                Divider()
                    .opacity(0.4)

                Text(copyright)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 520)
    }
}

// MARK: - Action button

private struct ActionButton: View {
    let title:  String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title  = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    AboutView()
}
