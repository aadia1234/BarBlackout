import SwiftUI

// Duration and Settings are now separate NSMenuItems in AppDelegate.
// This file is kept only for the combined canvas preview.

#if DEBUG
#Preview("Menu") {
    DurationView()
        .environmentObject(MenuBarManager.preview)
}
#endif
