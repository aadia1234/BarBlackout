import SwiftUI

struct BarBlackoutEntry: App {
    // AppDelegate owns the NSStatusItem + NSPopover and all AppKit lifecycle.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // A bare Settings scene satisfies the App protocol without creating a
        // Dock icon or any visible windows. The actual UI lives in the popover
        // managed by AppDelegate.
        Settings { EmptyView() }
    }
}
