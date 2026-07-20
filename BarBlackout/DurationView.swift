import SwiftUI

struct DurationView: View {
    @EnvironmentObject private var manager: MenuBarManager

    /// Called when the gear is tapped — AppDelegate toggles the slider row.
    var onGearTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(HideDuration.allCases.enumerated()), id: \.offset) { idx, dur in
                if idx > 0 { dot }
                durationButton(dur)
            }
            dot
            gearButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 310)
    }

    // MARK: - Subviews

    private func durationButton(_ dur: HideDuration) -> some View {
        // A custom slider value takes over, so no preset reads as active.
        let active = manager.hideDuration == dur
            && manager.hideMode != .off
            && manager.customMinutes == nil
        return ZStack {
            Circle()
                .fill(active ? Color.accentColor : Color(NSColor.controlColor))
                .frame(width: 24, height: 24)
            Group {
                if dur == .forever {
                    Image(systemName: "infinity")
                        .font(.system(size: 13, weight: .bold))
                } else {
                    Text(dur.label)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .foregroundColor(active ? .white : .primary)
        }
        .contentShape(Circle())
        .onTapGesture { manager.setHideDuration(dur) }
        .frame(maxWidth: .infinity)
    }

    private var gearButton: some View {
        let active = manager.customActive
        return ZStack {
            Circle()
                .fill(active ? Color.accentColor : Color(NSColor.controlColor))
                .frame(width: 24, height: 24)
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundColor(active ? .white : .secondary)
        }
        .contentShape(Circle())
        .onTapGesture { onGearTap() }
        .frame(maxWidth: .infinity)
    }

    private var dot: some View {
        Circle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 3, height: 3)
    }
}

#Preview {
    DurationView()
        .environmentObject(MenuBarManager.preview)
}
