/// BoseControl: Native macOS app for Bose QC Ultra 2

import SwiftUI

@main
struct BoseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = BoseManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                // Event-driven reads only (no poll): ContentView reads on open, and
                // this re-reads whenever the app regains focus. The v1 10 s poll
                // timer — the audio-dropout cause — is gone for good.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    manager.refreshState()
                }
        }
        .defaultSize(width: 640, height: 420)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)  // no title bar chrome — paper runs edge-to-edge
    }
}
