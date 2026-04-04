/// BoseControl: Native macOS menu bar app for Bose QC Ultra 2
/// Replaces Hammerspoon bar, Raycast toggle, and bosed daemon.

import SwiftUI

@main
struct BoseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { }  // Menu bar only — no main window
    }
}
