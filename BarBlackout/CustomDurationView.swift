import SwiftUI

/// Slider row that drops below the duration circles when the gear is tapped.
/// Picks a custom auto-off time from 0 to 24 hours in 15-minute steps.
struct CustomDurationView: View {
    @EnvironmentObject private var manager: MenuBarManager
    let width: CGFloat

    /// Local mirror so dragging stays smooth; committed to the manager on
    /// release rather than restarting the timer on every step.
    @State private var minutes: Double = 0

    private static let step: Double = 15
    private static let maxMinutes: Double = 24 * 60

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Custom")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Self.format(Int(minutes)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            AccentSlider(
                value: $minutes,
                range: 0...Self.maxMinutes,
                step: Self.step,
                onCommit: { manager.setCustomDuration(minutes: Int($0)) }
            )
            .frame(height: 20)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(width: width)
        .onAppear { minutes = Double(manager.customMinutes ?? 0) }
    }

    /// 0 → "∞", 90 → "1hr 30min", 45 → "45min"
    static func format(_ m: Int) -> String {
        guard m > 0 else { return "∞" }
        let h = m / 60, mins = m % 60
        switch (h, mins) {
        case (0, _):  return "\(mins)min"
        case (_, 0):  return "\(h)hr"
        default:      return "\(h)hr \(mins)min"
        }
    }
}

/// NSSlider wrapper. SwiftUI's `Slider` ignores `.tint` inside an NSMenu —
/// the menu's vibrant appearance overrides it and the fill renders gray — so
/// we drop to AppKit and set `trackFillColor` directly.
///
/// Quantisation happens here rather than via SwiftUI's `step:`, which would
/// draw a tick mark per step.
struct AccentSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onCommit: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider(value: value,
                         minValue: range.lowerBound,
                         maxValue: range.upperBound,
                         target: context.coordinator,
                         action: #selector(Coordinator.changed(_:)))
        s.isContinuous = true
        s.controlSize = .small
        s.trackFillColor = .controlAccentColor
        return s
    }

    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.parent = self
        if abs(s.doubleValue - value) > 0.01 { s.doubleValue = value }
        // Re-assert: the menu can reset it when appearance changes.
        s.trackFillColor = .controlAccentColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: AccentSlider
        init(_ parent: AccentSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            let snapped = (sender.doubleValue / parent.step).rounded() * parent.step
            sender.doubleValue = snapped
            parent.value = snapped
            // Commit on release only, so the timer isn't restarted mid-drag.
            if NSApp.currentEvent?.type == .leftMouseUp { parent.onCommit(snapped) }
        }
    }
}

#Preview {
    CustomDurationView(width: 310)
        .environmentObject(MenuBarManager.preview)
}
